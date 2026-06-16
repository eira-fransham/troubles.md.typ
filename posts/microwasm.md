# WebAssembly Troubles part 4: Microwasm

> ### Preamble
>
> This is the final part of a 4-part miniseries on issues with WebAssembly and proposals to fix them. [Part 1 here](http://troubles.md/wasm-is-not-a-stack-machine/), [part 2 here](http://troubles.md/why-do-we-need-the-relooper-algorithm-again/), [part 3 here](http://troubles.md/the-stack-is-not-the-stack/). This article assumes some familiarity with virtual machines, compilers and WebAssembly, but I’ll try to link to relevant information where necessary so even if you’re not you can follow along. Also, this series is going to come off as if I dislike WebAssembly. I love WebAssembly! I wrote a [whole article about how great it is](http://troubles.md/why-wasm/)! In fact, I love it so much that I want it to be the best that it can be, and this series is me working through my complaints with the design in the hope that some or all of these issues can be addressed soon, while the ink is still somewhat wet on the specification.

Wasm is mostly a great spec, but it has some serious problems. I’ve detailed some of these issues in the previous three articles in this series, but it might seem like actually fixing these problems is untenable. Are you _really_ going to deprecate locals? You’re going to deprecate `if`?

Well, turns out we don’t need to - we can get many of the desired benefits without dropping support for WebAssembly as it exists now.

## Introducing Microwasm

Microwasm (working title) is Wasm-compatible format that can be efficiently consumed by runtimes and efficiently produced by compilers like LLVM. It’s currently implemented in the [Microwasm branch of Lightbeam](https://github.com/CraneStation/lightbeam/pull/18). The main goals are as follows:

-   It should be relatively easy to implement each of the following three steps:
    -   Compiler IR->Microwasm;
    -   Wasm->Microwasm;
    -   Microwasm->Native.
-   It shouldn’t sacrifice any of WebAssembly’s guarantees on safety or determinism.
-   We should maximise the amount of useful information transferred from the compiler producing the Microwasm to the runtime consuming the Microwasm.
-   We should optimise for performance when consuming a stream of Microwasm, unless it conflicts with the performance goals of optimising compilers.
-   Converting Wasm to Microwasm must be possible to do in a streaming way, you shouldn’t need to block on loading a whole Wasm function before you’re able to produce Microwasm.
-   Wasm to Microwasm and then that Microwasm to native code should be precisely as performant as compiling the Wasm to native directly.

The last two points are the most important in my opinion. Basically what it means is that in the backends of [Wasmtime](https://github.com/CraneStation/wasmtime) we can just wrap the incoming Wasm stream in a streaming converter to Microwasm and consume that instead. This means our backends have the benefit of consuming a simpler language while not producing worse code. This means that while Wasm can enjoy the same performance that it already does, if a compiler wants to make use of Microwasm’s abiliy to allow improved performance then it can. Writing a Microwasm backend for most compilers would be much, much less costly than writing a Wasm backend and so it’s not like we have to convince compiler developers to maintain two equally huge backend codebases.

So how does it compare to WebAssembly? Well here’s a simple function from the Wasm specification tests:

```lisp
(module
  (func (param i32) (param i32) (result i32)
    get_local 1
    (block (result i32)
        get_local 0
        get_local 0
        br_if 0
        unreachable
    )
    i32.add
  )
)
```

Here’s that Wasm compiled to Microwasm:

```asm
.fn_0:
  pick 0
  pick 2
  pick 3
  br_if .L1_end, .L2
.L2:
  unreachable
.L1_end:
  i32.add
  br .return
```

The immediate differences in the format as it exists now:

-   No locals - arguments are passed on the stack when entering a function and locals are emulated by adding `swap` and `pick` instructions. This essentially means that `set_local`, `get_local` and `tee_local` are a no-op at runtime, they only affect the virtual stack;
-   Only CFG control flow, no hierarchical blocks like Wasm - this was modelled on the [Funclets](https://github.com/WebAssembly/funclets/blob/master/proposals/funclets/Overview.md) proposal for Wasm;
-   No block returns - only calling new blocks. Returning from a function is `br .return`. This isn’t proper [continuation-passing style](https://en.wikipedia.org/wiki/Continuation-passing_style), but it’s close enough that we get many of the simplicity benefits.

There’s another change that I’m considering where instructions that need data from the environment (for example, instructions that access the linear memory or the “table section”) have the environment passed in as an explicit argument. This reduces the special-casing in much of the translation code, but more importantly it allows us to free the register that this environment pointer would be stored in when we’re executing blocks that don’t need it. This would be a complex change to implement in the Wasm->Microwasm step though, so we’d want to work out for sure how it affects complexity and performance before making a firm decision either way.

The difference in quality of the generated code is immediately visible. Here’s Lightbeam’s assembly output for the function above before the implementation of Microwasm. I should say that the implementation of the backend that produced this is significantly more complex than the implementation using Microwasm:

```asm
  push rbp
  mov  rbp, rsp
  sub  rsp, 0x18
  mov  rax, rsi
  test eax, eax
  je   .L0
  mov  rax, rsi
  jmp  .L1
.L0:
  jmp  .L2
.L1:
  add  eax, edx
  mov  rsp, rbp
  pop  rbp
  ret
.L2:
  ud2
```

Now here’s the output after Microwasm:

```asm
  mov  rax, rsi
  mov  rcx, rdx
  mov  r8, rsi
  test esi, esi
  jne  .L0
  ud2
.L0:
  add  ecx, eax
  mov  rax, rcx
  ret
```

You can see that the control flow is much less noisy and the register usage is much better. The main problem you can see is that some registers are unnecessarily duplicated. In this case this can’t be avoided. We don’t know if the `block` will be broken out of again by a later instruction when we’re translating the `br_if` - remember, this is a streaming compiler and so we’re translating instruction by instruction - so we must assume that all arguments to the `end` label are disjoint even if currently we’ve only encountered jumps to it that give arguments including duplicates. The precise limitations of a streaming compiler in comparison to a traditional compiler deserve an article of their own, but for now the only important thing to say is that an optimising compiler producing Microwasm directly would be able to avoid this issue.

For comparison, here’s the assembly produced by Firefox’s optimising WebAssembly compiler. You can see that it’s much the same as our streaming compiler can produce:

```asm
  sub rsp, 8
  mov ecx, esi
  test edi, edi
  jne .L0
  ; .fail defined elsewhere
  jmp .fail
.L0:
  mov eax, ecx
  add eax, edi
  nop
  add rsp, 8
  ret
```

## Why not just a normal MIR?

The idea is that we can make changes that improve the simplicity of our codegen backend, keeping the format internal so we can see where the positives and pitfalls might lie. At this stage we’re compiling directly from Wasm so there’s an upper limit to how high-quality the code we generate can be; we’re still working with the same source information. It’s more like a streaming compiler-compatible MIR, except that it keeps all the security and sandboxing guarantees that WebAssembly has.

Once we’ve got a good idea of how we can get the most out of this format, we can allow frontends like LLVM to start generating it directly, which should give us an increase in performance with no extra work on our end. An LLVM Microwasm backend would be relatively simple to implement - where it differs from WebAssembly it’s simpler and where it’s similar to WebAssembly we can just reuse code from that backend.

## Why not just implement these changes in WebAssembly?

Well, that would be ideal. Maintaining a format, even a mostly-compatible one, is not an easy task. Besides, although you could have users supply code in this format in standalone environments, it will never be reasonable for multiple browsers to support both WebAssembly and a similar-but-different fork of the format. For code on the web to get the same benefits, these changes would have to be rolled into WebAssembly. So why won’t they be?

Well, the main answer is that V8 (Chrome’s JavaScript and WebAssembly engine) cannot easily support arbitrary CFGs - which are one of the two most important components of this format. In order to consume this format, V8 would have to either change their internal representation of control flow or implement the Relooper/Stackifier algorithm in the engine itself, and V8’s engineers have made it very clear that they have no interest in doing so. IonMonkey, Mozilla’s WebAssembly engine used by Firefox, apparently has a few optimisation passes that assume that the control flow graph is reducible (which WebAssembly’s control flow currently always is, while the proposed control flow would not necessarily be), but it doesn’t seem like the changes are as significant as those required in V8 and the team appears more willing to make them. The likelihood of me convincing the Chrome team to change their mind is zero, and the Chrome team has members that hold lifetime positions on the committee in charge of WebAssembly’s design. They have veto power over any changes in the specification and they are likely to use it.

So instead we can circumvent this issue by implementing our own compatible format. Maybe the improved freedom that we have to change this format will allow us to better prototype ideas that we’d like to include into WebAssembly proper. We can only hope.

This is the final part, so I don’t have a “join us next time” sequel tease. If you want more, read some of the other articles that I’ve posted or [go watch YouTube](https://www.youtube.com/watch?v=GyxTG1mucfs) or something. Either way, thanks for reading.
