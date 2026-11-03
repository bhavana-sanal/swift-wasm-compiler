// Runs a module produced by ternc under Node.js, supplying its `env` imports,
// and calls the exported `main`.
//
// usage: node run.mjs program.wasm
import { readFileSync } from "node:fs";

const bytes = readFileSync(process.argv[2]);
if (!WebAssembly.validate(bytes)) {
  console.error("error: not a valid WebAssembly module");
  process.exit(2);
}

// Output is buffered so that programs printing one character at a time
// don't pay for a write per call.
let output = "";
let memory;
const decoder = new TextDecoder();

const env = {
  print_i32: (value) => { output += value; },
  print_i64: (value) => { output += value; }, // arrives as a BigInt
  print_f64: (value) => { output += value; },
  print_str: (pointer) => {
    // Strings are a little-endian u32 byte length followed by UTF-8 bytes.
    const length = new DataView(memory.buffer).getUint32(pointer, true);
    output += decoder.decode(new Uint8Array(memory.buffer, pointer + 4, length));
  },
};

const { instance } = await WebAssembly.instantiate(bytes, { env });
memory = instance.exports.memory;

if (typeof instance.exports.main !== "function") {
  console.error("error: module does not export a 'main' function");
  process.exitCode = 2;
} else {
  try {
    instance.exports.main();
    process.stdout.write(output);
  } catch (error) {
    process.stdout.write(output);
    console.error(`trap: ${error.message}`);
    process.exitCode = 1;
  }
}
