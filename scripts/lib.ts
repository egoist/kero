// Shared helpers for the release scripts.

/** Print a highlighted progress line. */
export const say = (msg: string): void =>
  console.log(`\n\x1b[1;34m==>\x1b[0m ${msg}`);

/** Print an error and exit non-zero. */
export const die = (msg: string): never => {
  console.error(`\x1b[1;31merror:\x1b[0m ${msg}`);
  process.exit(1);
};

/** Exit unless an executable is on PATH. */
export const need = (tool: string): void => {
  if (!Bun.which(tool)) die(`missing required tool: ${tool}`);
};
