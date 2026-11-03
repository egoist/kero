// Installed by Kero (`kero skill setup`), which replaces it as Kero
// updates; `kero skill remove` removes it. Inside Kero, it tells Pi or
// OMP which session and pane it runs in, and tells Kero their session,
// to resume it after Kero's background service restarts. Outside Kero it
// does nothing.
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";

const KERO = __KERO__;
const AGENT = __AGENT__;

// hook runs `kero hook <agent>` as Claude Code runs its hooks, returning
// what Kero tells the agent.
function hook(sessionID: string | undefined): Promise<string> {
  return new Promise((resolve) => {
    const child = execFile(KERO, ["hook", AGENT], { timeout: 5000 }, (err, stdout) => {
      try {
        resolve(JSON.parse(stdout).hookSpecificOutput.additionalContext ?? "");
      } catch {
        resolve("");
      }
    });
    child.on("error", () => resolve(""));
    child.stdin?.end(JSON.stringify({ hook_event_name: "SessionStart", session_id: sessionID ?? "" }));
  });
}

export default function (pi: any) {
  if (!process.env.KERO_PANE) return;
  let context = "";
  let reported: string | undefined;
  const sync = async (ctx: any) => {
    // A terminal session, or a one-off prompt; not one a program drives.
    if (ctx?.mode !== "tui" && ctx?.mode !== "print") return;
    let sessionID: string | undefined;
    try {
      // OMP allocates a session id at start but writes the transcript only
      // with the first message. Kero would resume an id that has no file, so
      // report one only once it exists; the turn events report it as soon as
      // the first turn writes it.
      const file = ctx.sessionManager.getSessionFile();
      if (ctx.mode === "tui" && file && existsSync(file)) {
        sessionID = ctx.sessionManager.getSessionId();
      }
    } catch {}
    // Nothing new to tell, and a context already fetched: keep it.
    if (sessionID === undefined && context) return;
    // An in-app /resume switches the conversation under the same pane:
    // tell Kero the new id, or it would resume the one it saw last.
    if (sessionID !== undefined) {
      if (sessionID === reported) return;
      reported = sessionID;
    }
    context = await hook(sessionID);
  };
  pi.on("session_start", (_event: any, ctx: any) => sync(ctx));
  pi.on("session_switch", (_event: any, ctx: any) => sync(ctx));
  pi.on("agent_end", (_event: any, ctx: any) => sync(ctx));
  pi.on("turn_end", (_event: any, ctx: any) => sync(ctx));
  pi.on("before_agent_start", (event: any) => {
    if (!context) return;
    // Pi keeps prompt sections; OMP has none and replaces the prompt array.
    const sections = event?.systemPromptOptions?.sections;
    if (sections) {
      sections.kero = context;
      return;
    }
    if (Array.isArray(event?.systemPrompt)) {
      return { systemPrompt: [...event.systemPrompt, context] };
    }
  });
}
