// Managed by Kero. Re-enabling AI replaces this integration.
// KERO_INTEGRATION_ID=opencode
// KERO_INTEGRATION_VERSION=1

import net from "node:net";

const socketPath = process.env.KERO_AUTOMATION_SOCKET;
const token = process.env.KERO_AUTOMATION_TOKEN;
const terminalID = process.env.KERO_TERMINAL_ID;
let requestSequence = Date.now() * 1000;
let requestChain = Promise.resolve();
let lastState;

function enabled() {
  return process.env.KERO_AUTOMATION === "1"
    && !!socketPath
    && !!token
    && !!terminalID;
}

function report(state, reason) {
  if (state === lastState) return Promise.resolve();
  lastState = state;
  const pending = requestChain.then(() => reportOnce(state, reason));
  requestChain = pending.catch(() => {});
  return pending;
}

function reportOnce(state, reason) {
  if (!enabled()) return Promise.resolve();

  requestSequence += 1;
  const request = {
    version: 1,
    id: `kero:opencode:${requestSequence}`,
    method: "agent.report",
    token,
    terminalID,
    params: {
      state,
      reason: reason ?? `OpenCode lifecycle: ${state}`,
    },
  };

  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      socket.destroy();
      resolve();
    };
    socket.setTimeout(750, finish);
    socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", finish);
    socket.on("error", finish);
    socket.on("end", finish);
    socket.on("close", finish);
  });
}

function stateFromStatus(status) {
  const value = typeof status === "string" ? status : status?.type;
  switch (value?.toLowerCase()) {
    case "idle": return "idle";
    case "active":
    case "busy":
    case "pending":
    case "retry":
    case "running":
    case "streaming":
    case "working": return "working";
    default: return undefined;
  }
}

export const KeroAgentStatePlugin = async () => {
  if (!enabled()) return {};

  return {
    "chat.message": async () => report("working"),
    event: async ({ event }) => {
      const type = event?.type;
      const properties = event?.properties ?? {};
      switch (type) {
        case "session.status": {
          const state = stateFromStatus(properties.status);
          if (state) await report(state);
          break;
        }
        case "tool.execute.before":
        case "tool.execute.after":
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
        case "session.compacted":
          await report("working");
          break;
        case "permission.asked":
        case "question.asked":
        case "session.error":
          await report("blocked");
          break;
        case "session.idle":
          await report("idle");
          break;
        default:
          break;
      }
    },
  };
};
