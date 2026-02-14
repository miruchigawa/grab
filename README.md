# Grab: high-performance search in assembly

Grab is a search tool written in x64 assembly. It searches for exact string matches in files using AVX2 instructions and direct Linux system calls.

It's designed to be simple and efficient, avoiding the overhead of standard C libraries by talking directly to the kernel.

## Why assembly?

I wanted to see how much performance I could get by handwriting the search loop in assembly. The result is a tool that outperforms GNU grep for simple string searches on large files in my tests.

## Performance

Benchmarks on a 954MB file (enwik9) show speedups over GNU grep (LC_ALL=C):

| Pattern | GNU grep | Grab (AVX2) | Speedup |
| :--- | :--- | :--- | :--- |
| `Wikipedia` (~34k matches) | 579 ms | 137 ms | 4.2x |
| `Hutter Prize` (0 matches) | 522 ms | 133 ms | 3.9x |
| `The Hutter Prize for...` | 223 ms | 136 ms | 1.6x |
| `<` (3.6M matches) | 420 ms | 342 ms | 1.2x |

*Note: Benchmarks run on a hot file cache using `hyperfine` to isolate CPU performance.*

## How it works

The core search loop uses AVX2 SIMD instructions to process 32 bytes at a time.

- **Dual-check optimization:** It checks both the first and last characters of the search pattern simultaneously. This filters out false positives quickly, especially for longer patterns.
- **Direct system calls:** It uses raw Linux syscalls (`sys_open`, `sys_mmap`, `sys_write`, `sys_exit`) to avoid libc overhead.
- **Buffered output:** Matches are written to a 64KB internal buffer before being flushed to stdout, minimizing system call overhead.
- **Memory mapping:** The file is mapped into memory using `mmap`, letting the OS handle page caching and read-ahead.

## Build and usage

Requirements: `nasm`, `ld`, `make`.

```bash
make
./grab "pattern" filename
```

*Note: Multi-word patterns must be enclosed in quotes.*

## License

[MIT](LICENSE)
