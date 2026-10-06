import type { Plugin } from "@opencode-ai/plugin";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Coucou relay for OpenCode.
// Sends OpenCode lifecycle events to Coucou (macOS island / Windows+Linux Tauri)
// so sessions get their own pill, next to Claude Code.
// Rule: never block the agent — every send is fire-and-forget (detached spawn,
// errors swallowed). If no relay is installed, this plugin silently no-ops.

const AGENT = "opencode";
const MAX_PROMPT_LEN = 2000;

function hookCandidates(): string[] {
  const home = homedir();
  const candidates = [
    // macOS GitHub build (written by Coucou at launch)
    join(home, "Library/Application Support/NotchBuddy/nb-hook"),
    // macOS App Store build (written during hook installation)
    join(home, ".claude/coucou/nb-hook"),
    // Linux (Tauri build copies the relay here at startup)
    join(home, ".local/share/coucou/bin/coucou-hook"),
  ];
  // Windows (Tauri build copies the relay here at startup):
  // %LOCALAPPDATA%\Coucou\bin\coucou-hook.exe — spawned directly, no shell.
  const localAppData =
    process.env.LOCALAPPDATA ?? process.env.APPDATA ?? join(home, "AppData/Local");
  candidates.push(join(localAppData, "Coucou", "bin", "coucou-hook.exe"));
  return candidates;
}

let cachedHook: string | null | undefined;

function hookPath(): string | null {
  if (cachedHook !== undefined) return cachedHook;
  cachedHook =
    hookCandidates().find((p) => {
      try {
        return existsSync(p);
      } catch {
        return false;
      }
    }) ?? null;
  return cachedHook;
}

function send(event: string, payload: Record<string, unknown>): void {
  try {
    const hook = hookPath();
    if (!hook) return;
    const body =
      JSON.stringify({ hook_event_name: event, coucou_agent: AGENT, ...payload }) + "\n";
    // Spawn the relay directly: macOS nb-hook is a #!/bin/sh script (exec via
    // shebang), Linux coucou-hook is a binary, Windows coucou-hook.exe is a
    // binary. Never go through /bin/sh — it does not exist on Windows.
    const child = spawn(hook, ["--agent", AGENT, event], {
      stdio: ["pipe", "ignore", "ignore"],
      windowsHide: true,
    });
    child.on("error", () => {});
    try {
      child.stdin.on("error", () => {});
    } catch {
      // ignore — stdin may already be closed
    }
    try {
      child.stdin.write(body, () => {
        try {
          child.stdin.end();
        } catch {
          // ignore — never block the agent
        }
      });
    } catch {
      // ignore — EPIPE when Coucou is closed is fine
    }
    try {
      child.unref();
    } catch {
      // ignore
    }
  } catch {
    // ignore — never block the agent
  }
}

function textOf(parts: Array<{ type?: string; text?: string }>): string {
  const text = (parts ?? [])
    .filter((p) => p?.type === "text" && typeof p.text === "string")
    .map((p) => p.text as string)
    .join("\n")
    .trim();
  return text.length > MAX_PROMPT_LEN ? text.slice(0, MAX_PROMPT_LEN) + "…" : text;
}

export const CoucouPlugin: Plugin = async ({ directory }) => {
  // sessionID -> workspace directory (plugin `directory` is the fallback).
  // Coucou derives the pill's project name from `cwd`.
  const sessionDir = new Map<string, string>();
  const cwdOf = (sessionID?: string) => (sessionID && sessionDir.get(sessionID)) || directory;

  return {
    event: async ({ event }) => {
      try {
        const t = (event as { type?: string }).type;
        const props = (event as { properties?: any }).properties ?? {};
        if (t === "session.created" || t === "session.updated") {
          const info = props.info ?? {};
          if (info.id && info.directory) sessionDir.set(info.id, info.directory);
          if (t === "session.created" && info.id) {
            send("SessionStart", { session_id: info.id, cwd: info.directory ?? directory });
          }
        } else if (t === "session.deleted") {
          const id = props.info?.id ?? props.sessionID;
          if (id) {
            send("SessionEnd", { session_id: id, cwd: cwdOf(id) });
            sessionDir.delete(id);
          }
        } else if (t === "session.idle") {
          if (props.sessionID) {
            send("Stop", { session_id: props.sessionID, cwd: cwdOf(props.sessionID) });
          }
        } else if (t === "session.error") {
          const id = props.sessionID as string | undefined;
          if (!id) return;
          const msg = String(props.error?.data?.message ?? props.error?.message ?? "").slice(0, 500);
          if (/rate.?limit/i.test(msg)) {
            send("Notification", { session_id: id, cwd: cwdOf(id), message: msg });
          } else {
            send("StopFailure", { session_id: id, cwd: cwdOf(id), message: msg });
          }
        }
      } catch {
        // ignore — never block the agent
      }
    },

    "chat.message": async (input, output) => {
      try {
        const prompt = textOf(output.parts as Array<{ type?: string; text?: string }>);
        send("UserPromptSubmit", {
          session_id: input.sessionID,
          cwd: cwdOf(input.sessionID),
          prompt,
        });
      } catch {
        // ignore — never block the agent
      }
    },

    "tool.execute.before": async (input, output) => {
      try {
        send("PreToolUse", {
          session_id: input.sessionID,
          cwd: cwdOf(input.sessionID),
          tool_name: input.tool,
          tool_input: output.args ?? {},
        });
      } catch {
        // ignore — never block the agent
      }
    },

    "tool.execute.after": async (input) => {
      try {
        send("PostToolUse", {
          session_id: input.sessionID,
          cwd: cwdOf(input.sessionID),
          tool_name: input.tool,
          tool_input: (input as { args?: unknown }).args ?? {},
        });
      } catch {
        // ignore — never block the agent
      }
    },
  };
};

export default CoucouPlugin;
