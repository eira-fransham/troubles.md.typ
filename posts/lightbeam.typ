#let links = (
  lightbeam: "https://github.com/CraneStation/lightbeam",
  firefox-streaming: "https://hacks.mozilla.org/2018/01/making-webassembly-even-faster-firefoxs-new-streaming-and-tiering-compiler/",
  wasmtime: "https://github.com/bytecodealliance/wasmtime",
  substrate: "https://github.com/paritytech/substrate",
  why-wasm: <why-wasm>,
  sse4: "https://en.wikipedia.org/wiki/SSE4",
  jvm-jit: "https://www.slideshare.net/ZeroTurnaround/vladimir-ivanovjvmjitcompilationoverview-24613146",
  wasmi: "https://github.com/paritytech/wasmi",
  stack-machine: "https://en.wikipedia.org/wiki/Stack_machine",
  relooper-article: <why-do-we-need-the-relooper-algorithm-again>,
  wasm-is-not-a-stack-machine: <wasm-is-not-a-stack-machine>,
  ssa: "https://en.wikipedia.org/wiki/Static_single_assignment_form",
  cfg: "https://en.wikipedia.org/wiki/Control-flow_graph",
  lifo-queue: "https://en.wikipedia.org/wiki/Stack_(abstract_data_type)",
)

#let footnotes = (
  conditional-branch: [
    It would technically be possible to collapse `br_table` and `br_if` into a single construct but there are optimisations that you can do for the latter that aren’t possible with the former, so we’d just end up converting it back later on. I might actually do this later since it means that we can focus optimisation on just a single place (so if we get a two-target `br_table` as input we generate code as good as for a `br_if`), but for now they’re separate. We could even collapse `br` into `br_table` with one element, giving us only one possibility to work with.
  ],
  multi-caller: [
    In a “proper” optimising compiler that doesn’t need to support streaming compilation, you can do optimisations on blocks with more than one caller but a streaming compiler can only do these optimisations for blocks with precisely one caller. I won’t go into precisely why this is now, I’ll leave that as an exercise for the reader, but I might revisit it in a future article.
  ],
  local-troubles: [
    Why they didn’t have it return the _old_ value of the local is beyond me, since that’s a lot harder to emulate (requiring you to generate an extra local). The current behaviour is trivially emulateable. I presume it’s related to Wasm’s roots as a binary representation of asm.js and the fact that JavaScript allows `a = b = c = d`, but that’s just speculation.
  ],
  x86-addition: [
    Technically `+` is a bad example since you can emulate 3-argument `add` with `lea`, but bear with me here.
  ],
  aliasing: [
    We have the same problem with values that are constants as we have for aliasing values - if we return a constant for a specific variable but then this block is called with a different value for that constant then we’ll end up with the wrong result.
  ],
)

#link(links.lightbeam)[Lightbeam] is a new streaming compiler for WebAssembly, designed to produce the best possible assembly while still being fast enough to produce assembly faster than the WebAssembly is received over the wire.

WebAssembly was designed for streaming compilation, and even from its first public release there was a streaming implementation - #link(links.lightbeam)[Firefox has had its own optimising streaming compiler for a long time] and V8 has LiftOff.

Lightbeam is similar in concept, but has a different internal mechanism which leads to surprisingly high-quality code considering the constraints, and I’ll explain how it works in this article.

= Lightbeam

Lightbeam is intended for use as the initial compiler in #link(links.wasmtime)[Wasmtime] and as the main compilation engine for Substrate‘s smart contract subsystem.

In relation to the latter, you might have some questions: Why do we need a compiler for our smart contracts? What even are smart contracts? We really want to put a compiler in a blockchain client? For answers to these questions and more you can check out #link(links.why-wasm)[my article about WebAssembly on the blockchain], but it’s not particularly important for the purposes of this article.

What is important is how WebAssembly works and how we can work around its limitations to produce high-quality code in a streaming compiler.

= Streaming compilation

So I’m not going to go too deep into this since Lin Clark has #link(links.firefox-streaming)[already covered this much more thoroughly] than I can, but here’s the pitch. If you want to have fast startup times for a program, you have a few options, each with their own pros and cons:

- Distribute the program as machine code
  - Pros: Very fast, predictable performance
  - Cons: Massively insecure, can’t use #link(links.sse4)[microarchitecture-specific opcodes] without extra complexity and runtime checks, must distribute separate versions of the program for each target platform
- Distribute bytecode and use an interpreter
  - Pros: Easy to implement, easy to debug, easy to add extra functionality, easy to ensure correctness, easy to write a convenient API, 100% thread- and memory-safe by default, portable to any platform that the host language is
  - Cons: Slow (really, really slow)
- Distribute bytecode and use a JIT
  - Pros: Very fast startup and execution, can lazily compile functions (so unused functions are never compiled), can take advantage of host microarchitecture, can do #link(links.jvm-jit)[incredibly powerful optimisation techniques] that are impossible with ahead-of-time compilation
  - Cons: Easily the most complex option, no thread- or memory-safety by default, good average-case startup but without extremely careful implementation can have very bad worst-case startup time, must implement a different backend for each target architecture
- Distribute bytecode and use streaming compilation
  - Pros: Can give very good performance with good bytecode design, relatively easy to ensure worst-case startup time is low, can take advantage of host microarchitecture
  - Cons: Must implement a different backend for each target architecture, no thread- or memory-safety by default, need to design bytecode around constraints of streaming compilation

The main reason we decided to use a streaming compiler at Parity is that the strict bounds on compilation time are necessary in the context of the blockchain, currently we use #link(links.wasmi)[our own in-house WebAssembly interpreter].

Any one of these can be combined with a slower but more-powerful compiler that works in the background as the more immediate method of execution is running the program, with execution switching to the output of the heavyweight compiler when it’s ready.

= WebAssembly primer

So to explain what Lightbeam does internally, I need to explain a few things about WebAssembly. WebAssembly is a weird middle-ground between a high-level language and a more traditional bytecode. It is a bytecode in that it’s a #link(links.stack-machine)[stack machine], canonically represented as a series of opcodes instead of using a text-based format, but it has many high-level features that are rarely seen in bytecodes, like having hierarchical blocks using `block...end` that you can break out of, a separate block type for blocks that you can jump to the end of and blocks that you can jump to the start of, and an `if..else..end` construct instead of a using more traditional “test-and-jump” instruction (it also has a test-and-jump instruction, but you currently #link(links.relooper-article)[can’t use it to emulate if statements]). Plus, it has “locals”, a concept similar to variables in most high-level languages. These locals are #link(links.wasm-is-not-a-stack-machine)[actually more trouble than they’re worth], however, they’re more an artifact of WebAssembly’s history than a useful feature.

So although WebAssembly is designed to be easily compiled and easily compiled with a streaming compiler, it’s actually pretty non-trivial to generate optimal code from WebAssembly directly. That’s why Lightbeam doesn’t.

= Gotta go fast

So, how does Lightbeam get such good code? Well, there’s lots of small optimisations that make it possible, but we start by converting to an #link(links.ssa)[SSA], #link(links.cfg)[CFG] intermediate representation like a “normal”, non-streaming compiler would. This is comparable to LLVM IR or Cranelift IR - a simpler version of the input code that allows you to perform optimisations without having to deal with as many cases. I’ll get into precisely how this differs from WebAssembly later. The difference between this and LLVM IR is that Lightbeam’s IR conversion is streaming - we can convert a stream of WebAssembly to a stream of IR and the backend can convert a stream of IR to a stream of native code. In practice this means that we can generate native code with only one-opcode lookahead.

In the backend we keep track of where values are stored, so that we don’t need to move items around unless absolutely necessary. The upshot of this is that values stay in registers as much as possible and often do not need to be spilled to memory - and when they are spilled to memory they’re spilled in order of least-recently-used. Currently we have 4 kinds of value locations: a value can be stored in memory, in a register, in a constant or as a condition code. The latter means that where many streaming compilers would emit a comparison, a conversion of the comparison’s result to an integer, a comparison of that integer to 0, and then a jump, in Lightbeam we just emit a comparison and then a jump on that condition code, just as a non-streaming compiler would. We also get constant folding for free with this method, all without sacrificing streaming.

In our case we simplify `if..end`, `if..else..end`, `br_if`, `br_table`, `block..end` and `loop..end` constructs to a single, flat form. Instead of nested blocks like WebAssembly, we have a flat list of basic blocks which must end with `br`, `br_if` or `br_table`. Instead of having many ways to switch control flow, we only have 3#footnote(footnotes.conditional-branch). Entering a `block` becomes a no-op, but `if`, `else`, `loop` and `end` need to be converted into this form. This is luckily extremely simple in practice.

One very useful fact is that there’s no way for a block to jump without also ending the block, which simplifies a lot. Unfortunately, WebAssembly does allow that, so we have some complications. Consider the following WebAssembly:

```lisp
(block (result i32)
    i32.const 1
    i32.const 2
    get_local 0
    br_if 0
    i32.add
)
```

So what this does is returns the `2` constant from the function if local `0` is non-zero, and otherwise returns the `1` and `2` constants added together. That is, the `1` is discarded _only if the branch is taken_. In the Lightbeam IR we explicitly state which elements are dropped for each branch target, which means that it is impossible to forget to handle this case or to handle it incorrectly - a branch where nothing is discarded and a branch where something is discarded are treated the same.

We also annotate each block header with the number of calls and whether it may have backwards callers - there are optimisations you can do when a block has precisely one caller#footnote(footnotes.multi-caller) and we can omit generating code for blocks with zero callers entirely. Because of Wasm’s approach to control flow we can’t always know ahead of time how many callers a block will have so as a backup we count the number of callers ourselves. For blocks that can have backwards callers (i.e. those generated from Wasm loop instructions, since branch instructions branch to the loop’s header), however, that doesn’t work, and so we explicitly mark any block that could have backwards callers. You can see that without making this information simple and explicit in the IR doing optimisations related to this would be prohibitively complex.

The meat of the compiler comes in the form of the virtual stack. This is a #link(links.lifo-queue)[LIFO queue] of value locations, which can be either:

- Stack: A location on the physical stack (i.e. a memory location that is an offset to `rsp`). Since `rsp` can change within a function, this is stored as an offset from what `rsp` was at the start of the function and the real offset is recalculated each time the value is accessed.
- Register: A value in a register. I go over some important subtleties related to this further down.
- Immediate: A constant value, which allows us to fold constants and do optimisations like using the immediate-operand version of instructions like add instead of spilling the constant to a register first.
- Condition code: A value that represents one of the bits in the `FLAGS` register. This means that a comparison operation followed by a `select` or `br_if` can be compiled to one of the cc forms of the associated instructions. For example, `i32.lt_u` + `select` compiles to `cmp` + `cmovb`, the `cmp` instruction sets some flags on the CPU and the `cmovb` reads the flags and sets the corresponding register to a certain value if the `b` flag is set. Since there’s only one `FLAGS` register and many things overwrite it, we spill this kind of value to a register if anything gets pushed onto the stack on top of it. In the future we’d like to be able to only spill a condition code if we actually do an operation that overwrites it.

An important thing about our “register” type is that registers are refcounted. To see why that’s important, we have to talk about locals.

In WebAssembly, there are two kinds of place that a value can be: on the (virtual) stack or in a local. You can move a value from the stack to a local with `set_local` and from a local to the stack with `get_local`. There’s also `tee_local`, which is equivalent to `set_local` followed by `get_local`#footnote(footnotes.local-troubles). Anyway, for our purposes the important thing is that `get_local` cause a value to be duplicated. This also applies to `tee_local` but we’ll ignore that for now for simplicity’s sake. If you have some system for tracking register uses, for example, where a register can be reused when it’s no longer to be possible to access the value that was previously in it, you need to refcount registers, so that you can, for example, do a `get_local` followed by overwriting the value in that local without causing the old value on the stack to magically change or otherwise become invalid. This allows us to do some other optimisations though.

For example, on x86 you don’t really have a `+` operator4, you only have `+=`. Normally you’d need to allocate a new register, copy the LHS of the operator into it and add the RHS in-place, but if the refcount on that register is precisely 1 you can operate on it in-place. Another use of refcounting in a streaming compiler is that although in straight-line code you can have aliasing values, when you start a loop (and in some other circumstances) you have to have all your locals and stack elements in unique places. To illustrate why this is, let’s use an example. Here’s a simple loop in WebAssembly:

```lisp
(func $bad_factorial (param $param i32)
  (local $counter i32)
  (local $output i32)
  (set_local $counter (get_local $param))
  (set_local $output (get_local $counter))
  (loop
    (set_local $counter
      (i32.sub (get_local $counter)
               (i32.const 1)))
    (set_local $output
      (i32.mul (get_local $output)
               (get_local $counter)))
    (br_if 0 (i32.ne (get_local $counter) (i32.const 0)))
  )
  (return (get_local $output))
)
```

So in this function, when the loop starts both locals point to the same place. This is bad, since after the first iteration they will have non-aliasing locations and if we generate code that looks in the same place for both variables we’ll end up returning the wrong result. We could choose arbitrary but static and non-aliasing locations for values used by blocks (in the same way that functions have a specific calling convention called SystemV) but we want to avoid moving values around if possible. So, the first time a block is called we try to set the block’s calling convention to whatever the locations of values happen to be at the first call. When we set the calling convention for the first time, we allocate the minimum number of new locations that will remove any aliasing values. This is why it’s important that we know if a block has precisely one caller: if it only has one caller then we can always keep values where they are. If there are aliasing values then that’s fine, since we know that it’s impossible for this block be called with non-aliasing values#footnote(footnotes.aliasing).

For a deeper explanation of Lightbeam’s IR check out #link(links.wasm-is-not-a-stack-machine)[the article series that lead me to develop it].

= What does this mean for me?

If you’re just someone who interacts with WebAssembly as a consumer - i.e. you write code that compiles to WebAssembly and the Wasm runtime is just a black box - you might be asking what this means for you. Well, this means that Wasmtime can have vastly better startup performance, and will almost certainly have much more consistent startup performance. Other than that, it’s probably something that will be mostly transparent for you. It’s the same as V8’s LiftOff or FireFox’s baseline compiler, but for Wasmtime. However, I hope this article gives an amount of insight into how this unconventional form of compiler can work.
