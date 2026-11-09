// Trusted runner for keys.py (Deno, no permissions except reading the two pinned public module files).
// stdin: the full key-response JSON text (<= 4096 bytes). stdout: exactly 16 bytes. Nothing else is ever printed.
// Exit codes are static: 2 input, 3 module, 4 decode, 5 result length.
const MAX_INPUT = 4096;

async function readInput() {
  const chunks = [];
  let total = 0;
  for await (const chunk of Deno.stdin.readable) {
    total += chunk.length;
    if (total > MAX_INPUT) return null;
    chunks.push(chunk);
  }
  if (total === 0) return null;
  const all = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) { all.set(c, at); at += c.length; }
  return all;
}

function fileUrl(path) {
  const u = new URL("file:///");
  u.pathname = path;
  return u.href;
}

let text;
try {
  const bytes = await readInput();
  if (bytes === null) Deno.exit(2);
  text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
} catch {
  Deno.exit(2);
}

let runtime;
try {
  const [runtimePath, corePath] = Deno.args;
  runtime = await import(fileUrl(runtimePath));
  runtime.initSync({ module: Deno.readFileSync(corePath) });
} catch {
  Deno.exit(3);
}

let key;
try {
  key = runtime.decode_session(text);
} catch {
  Deno.exit(4);
}
if (!(key instanceof Uint8Array) || key.length !== 16) Deno.exit(5);

let written = 0;
while (written < key.length) written += Deno.stdout.writeSync(key.subarray(written));
