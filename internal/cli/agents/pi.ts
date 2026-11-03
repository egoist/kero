// Installed by Kero (`kero skill setup`), which replaces it as Kero
// updates; `kero skill remove` removes it. Inside Kero, it tells Pi or
// OMP which session and pane it runs in, and tells Kero their session,
// to resume it after Kero's background service restarts. Outside Kero it
// does nothing.
import { execFile } from "node:child_process";

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
      if (ctx.mode === "tui" && ctx.sessionManager.getSessionFile()) {
        sessionID = ctx.sessionManager.getSessionId();
      }
    } catch {}
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
