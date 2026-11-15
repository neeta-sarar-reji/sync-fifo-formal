# Formal Verification of a Synchronous FIFO

Formal verification of a parameterized synchronous FIFO (`DEPTH` a power of two, `DWIDTH` any width) using **Yosys**, **SymbiYosys** and **Boolector**.

## Table of Contents

1. [Repository contents](#1-repository-contents)
2. [Synchronous FIFO theory](#2-synchronous-fifo-theory)
3. [Design in this repository](#3-design-in-this-repository)
4. [Formal verification approach](#4-formal-verification-approach)
5. [How to run](#5-how-to-run)
6. [Results](#6-results)
7. [Mutation testing](#7-mutation-testing)
8. [Limitations and future work](#8-limitations-and-future-work)

---

## 1. Repository contents

| File | Description |
|------|-------------|
| `sync_fifo_full.v` | FIFO RTL with embedded formal properties (inside `` `ifdef FORMAL ``) |
| `fifo.sby` | SymbiYosys configuration with `bmc`, `prove` and `cover` tasks |
| `mutate.sh` | Mutation testing script (optional, checks the properties catch injected bugs) |
| `.gitignore` | Ignores generated SymbiYosys output folders |

---

## 2. Synchronous FIFO theory

### 2.1 What is a FIFO?

A **FIFO (First-In, First-Out)** is a buffer in which data is read out in exactly the order it was written. The first word written is the first word read. It behaves like a queue at a ticket counter.

### 2.2 Why FIFOs are used

- **Rate matching:** a producer that writes in bursts and a consumer that reads at a steady rate can be decoupled.
- **Buffering:** absorbs short-term differences in throughput so that no data is lost.
- **Pipeline decoupling:** lets one block stall without immediately stalling the block feeding it.
- **Data ordering:** guarantees that order is preserved between blocks.

Typical uses include UART/SPI/I2C buffers, packet buffers in network logic, DMA engines, and streaming video or audio pipelines.

### 2.3 Synchronous vs asynchronous FIFO

| Property | Synchronous FIFO | Asynchronous FIFO |
|----------|------------------|-------------------|
| Clocks | One clock for read and write | Separate read and write clocks |
| Pointer comparison | Directly comparable | Needs clock domain crossing (Gray code + synchronizers) |
| Complexity | Low | Higher |
| Typical use | Buffering within a single clock domain | Moving data between clock domains |

This project covers the **synchronous** case, where read and write logic share `clk`.

### 2.4 Block-level structure

```
                +------------------------------------------+
   wr_en  ----->|  write logic  --> wptr                    |
   din    ----->|                    |                      |
                |                    v                      |
                |             +-------------+               |
                |             |   storage   |               |
                |             |  fifo[0..   |               |
                |             |   DEPTH-1]  |               |
                |             +-------------+               |
                |                    ^                      |
   rd_en  ----->|  read logic   --> rptr                    |----> dout
                |                                           |
                |  flag logic (wptr, rptr) --> full, empty, |----> full / empty / count
                +------------------------------------------+
```

The building blocks are:

1. **Storage array:** a small memory (registers or RAM) holding `DEPTH` words of `DWIDTH` bits.
2. **Write pointer (`wptr`):** index of the next location to be written.
3. **Read pointer (`rptr`):** index of the next location to be read.
4. **Flag logic:** generates `full` and `empty` from the two pointers.

### 2.5 How the pointers work

- On a successful **write**, `din` is stored at `fifo[wptr]` and `wptr` increments.
- On a successful **read**, the word at `fifo[rptr]` is output and `rptr` increments.
- Both pointers **wrap around** to 0 after reaching the last location. The storage therefore behaves as a **circular buffer**.
- The number of stored words is the distance from `rptr` to `wptr`.

A write is only accepted when the FIFO is **not full**, and a read is only accepted when it is **not empty**. Writing into a full FIFO would overwrite unread data (**overflow**). Reading from an empty FIFO would return invalid data (**underflow**).

### 2.6 The full/empty ambiguity problem

If the pointers are just `log2(DEPTH)` bits wide, then `wptr == rptr` happens in **two different situations**:

- the FIFO is **empty** (nothing written since the last read), or
- the FIFO is **full** (the write pointer has gone all the way around and caught up with the read pointer).

The two cases cannot be told apart from the pointers alone. There are two classical solutions.

**Option A: sacrifice one slot.** Declare the FIFO full when `wptr + 1 == rptr`. This needs no extra state, but the usable capacity is only `DEPTH - 1`.

**Option B: add one extra pointer bit (the "lap" bit).** Make each pointer `log2(DEPTH) + 1` bits wide. The lower bits address the memory, and the top bit toggles each time the pointer wraps. Then:

| Condition | Meaning |
|-----------|---------|
| `wptr == rptr` (all bits) | **Empty:** same lap, same address |
| Lap bits differ **and** lower bits equal | **Full:** write pointer is exactly one lap ahead |

This design uses **Option B**, so the full `DEPTH` locations are usable.

### 2.7 Occupancy count

Because the pointers carry the lap bit, the number of stored words is simply

```
count = wptr - rptr        (computed in log2(DEPTH)+1 bits, wraps correctly)
```

and the flags can be written equivalently as `empty = (count == 0)` and `full = (count == DEPTH)`. Having `count` makes properties easy to state, which is useful for formal verification.

### 2.8 Read timing: registered output vs first-word-fall-through

There are two common read styles:

- **Registered (standard) read:** `dout` is a register, loaded when `rd_en` is accepted. Data appears **one clock cycle after** the read request.
- **First-Word-Fall-Through (FWFT):** the oldest word is always visible on the output, and `rd_en` acts as an acknowledge that consumes it.

This design uses the **registered read** style, so read latency is **one cycle**.

### 2.9 Corner cases

| Situation | Behaviour in this design |
|-----------|--------------------------|
| Write while full | Ignored (no overflow, pointers unchanged) |
| Read while empty | Ignored (no underflow, pointers unchanged) |
| Read and write in the same cycle (neither full nor empty) | Both happen, `count` stays the same |
| Read and write in the same cycle while **empty** | Only the write happens (read is blocked by `empty`) |
| Read and write in the same cycle while **full** | Only the read happens (write is blocked by `full`) |
| Reset | Pointers cleared to 0, `dout` cleared to 0, FIFO becomes empty |

### 2.10 Choosing the depth

The required depth depends on the burst behaviour. A common rule of thumb for a burst of `B` words written at rate `Rw` and read at rate `Rr` (with `Rw > Rr`) is:

```
DEPTH >= B * (1 - Rr / Rw)
```

Using a power-of-two depth keeps the pointer wrap-around free, since the pointer overflow itself provides the modulo.

---

## 3. Design in this repository

### 3.1 Interface

| Signal | Direction | Description |
|--------|-----------|-------------|
| `clk` | in | Clock |
| `rstn` | in | Active-low synchronous reset |
| `wr_en` | in | Write request |
| `rd_en` | in | Read request |
| `din[DWIDTH-1:0]` | in | Write data |
| `dout[DWIDTH-1:0]` | out | Read data (registered) |
| `empty` | out | High when no words are stored |
| `full` | out | High when `DEPTH` words are stored |
| `count[$clog2(DEPTH):0]` | out | Number of stored words, 0 to `DEPTH` |

### 3.2 Parameters

| Parameter | Default | Constraint |
|-----------|---------|------------|
| `DEPTH` | 8 | Power of two, at least 2 |
| `DWIDTH` | 16 | At least 1 |

### 3.3 Key internal signals

```verilog
wire do_wr = wr_en & !full;     // accepted write
wire do_rd = rd_en & !empty;    // accepted read

assign empty = (wptr == rptr);
assign full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
assign count = wptr - rptr;
```

---

## 4. Formal verification approach

### 4.1 Why formal?

Simulation only tests the cases the testbench happens to produce. Formal verification explores **all** reachable input sequences within the tool's bounds, and with k-induction it can prove properties for **unbounded** time. A FIFO is a good formal target because its important behaviour (pointer wrap-around, full/empty corner cases, simultaneous read and write) is exactly the kind of thing directed tests tend to miss.

### 4.2 Tool flow

- **Yosys** reads the design and converts it to a formal model.
- **SymbiYosys (sby)** drives the tasks (`bmc`, `prove`, `cover`).
- **Boolector** is the SMT solver that decides each query.

### 4.3 Modes used

| Mode | Purpose |
|------|---------|
| `cover` | Shows interesting states are reachable (guards against vacuous proofs) |
| `bmc` | Bounded model checking: searches for counterexamples up to a fixed depth |
| `prove` | BMC base case plus k-induction: proves properties for all cycles |

### 4.4 Properties checked

**Assumptions**

- The design starts in reset (`rstn` low in the first cycle).

**Safety assertions**

1. `count <= DEPTH` (occupancy never exceeds capacity).
2. `empty == (count == 0)` and `full == (count == DEPTH)`.
3. `full` and `empty` are never high together.
4. After reset, `wptr`, `rptr` and `dout` are 0.
5. `count` increases by 1 on a write only, decreases by 1 on a read only, and is unchanged when both or neither happen.
6. Pointers hold when a write or read is not accepted (no overflow, no underflow).

**Data integrity (scoreboard)**

The checker tracks **one arbitrary word** through the FIFO using two unconstrained constants (`anyconst`): `f_idx` (which pointer value to follow) and `f_data` (the data value). Since the solver may pick any value for these, proving the property for this one tracked word covers every word and every position. The check is:

- when the tracked word is written, `din == f_data`;
- when it is later read, `dout == f_data`.

Two helper invariants make k-induction succeed:

- `f_tracked` is true exactly when the tracked index lies inside the stored window (`f_idx - rptr < count`);
- while tracked, the memory location really holds `f_data`.

**Cover properties**

- FIFO becomes full.
- FIFO becomes empty right after being full.
- FIFO reaches half full.
- The scoreboard read-check path is exercised.
- Both pointers wrap around (lap bit set on both).

---

## 5. How to run

Activate the OSS CAD Suite in each new terminal:

```bash
source ~/Downloads/oss-cad-suite/environment
```

Then run the tasks from the repository folder:

```bash
sby -f fifo.sby cover   # reachability of interesting states
sby -f fifo.sby bmc     # bounded model check, depth 25
sby -f fifo.sby prove   # unbounded proof using k-induction
```

Output is created in `fifo_cover/`, `fifo_bmc/` and `fifo_prove/`. Cover waveforms are in `fifo_cover/engine_0/trace*.vcd` and can be opened with GTKWave:

```bash
gtkwave fifo_cover/engine_0/trace3.vcd
```

To change the size, edit the `chparam` line in `fifo.sby`:

```
chparam -set DEPTH 8 -set DWIDTH 16 sync_fifo_full
```

---

## 6. Results

For `DEPTH = 4`, `DWIDTH = 4`:

| Task | Result |
|------|--------|
| `cover` | PASS: all cover points reached |
| `bmc` (depth 25) | PASS: no assertion failures |
| `prove` | PASS: successful proof by k-induction |

---

## 7. Mutation testing

A proof is only meaningful if the properties can fail on a broken design. `mutate.sh` injects deliberate bugs into a copy of the RTL and checks that each one is caught:

| Mutation | Bug injected |
|----------|--------------|
| `no_full_check` | Writes are accepted while full |
| `no_empty_check` | Reads are accepted while empty |
| `corrupt_data` | Written data is altered |
| `bad_full_flag` | Wrong lap-bit comparison in `full` |

Run it with:

```bash
./mutate.sh
```

Every mutation should report `bug CAUGHT`.

---

## 8. Limitations and future work

- Results above are for small parameters; larger sizes should be re-run for confirmation.
- The design is a registered-read FIFO, not first-word-fall-through.
- Possible extensions: almost-full / almost-empty flags, a FWFT variant, an asynchronous FIFO with Gray-coded pointers, and checking behaviour when reset is asserted mid-operation.
