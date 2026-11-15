# Formal verification of a synchronous FIFO

Formal verification of a parameterized synchronous FIFO
(`DEPTH` power of two, `DWIDTH` any width) using
Yosys, SymbiYosys and Boolector.

## Files
- `sync_fifo_full.v`: RTL with embedded formal properties (`ifdef FORMAL`)
- `fifo.sby`: SymbiYosys config with `bmc`, `prove` and `cover` tasks

## Properties checked
- Occupancy never exceeds DEPTH
- `full`/`empty` flags consistent with `count`
- Pointers hold on overflow/underflow attempts
- Data integrity via a tracked-word scoreboard
- Cover goals: full, empty after full, half full, pointer wrap-around

## Run
    source ~/Downloads/oss-cad-suite/environment
    sby -f fifo.sby cover
    sby -f fifo.sby bmc
    sby -f fifo.sby prove

## Status
cover, bmc (depth 25) and prove (k-induction) pass for DEPTH=4, DWIDTH=4.
