// Chapel Hello World
// Run with: chpl hello.chpl && ./hello

writeln("Hello, Chapel!");

// Parallel hello from multiple tasks
coforall i in 1..4 do
  writeln("Hello from task ", i);
