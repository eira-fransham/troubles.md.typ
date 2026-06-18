This article is a story about optimising the size and performance of `std::borrow::Cow<T>` in Rust. It requires some basic knowledge of programming Rust, but doesn’t require any knowledge of the kind of low-level details of Rust’s compilation model. We’ll be touching on some pretty low-level subjects later on but I’ll explain them as we go. The optimisations will start pretty reasonable, but will continue to get more disgusting and cursed until all hell breaks loose and the skies themselves turn blood red with the rage of the ancients.

Anyway, to start things off, let’s briefly talk about pointers.

Specifically, let’s talk about _array_ pointers. In C, array pointers are the same as “normal” pointers, and have no size or other metadata attached. If you want to know the size of an array in C, you have to implement that yourself. For strings, this is tradionally implemented by ending the string with a “sentinel value”, so when iterating over the string you can continuously check for this value and exit. For other arrays, this is usually implemented by supplying some metadata as an additional parameter to the function or as a field in a struct. For a safe language like Rust, though, this simply doesn’t fly. Rust has a type `&[T]`, which represents a borrowed array, and `Box<[T]>`, which is an owned array. Both of these use the same syntax as “normal” pointers to a single element, but additionally store their length using some magic in the compiler itself. You can think of pointers in Rust being split into two different types: the pointer-to-sized-type (a pointer to a type whose size is known at compile-time, like `&u64`, `&[u8; 10]`, `&()`, and so forth) and the pointer-to-unsized-type (a pointer to a type whose size is only known at runtime, such as `&[u8]`, `&str` or `&dyn Trait`).

```rust
struct Ptr<T>
where
    T: Sized
{
    address: usize,
}

struct Ptr<T>
where
    T: !Sized
{
    address: usize,
    // Rust currently only ever uses a pointer or pointer-sized integer for the fat pointer
    // extra data, but in theory we could have anything here, and it could be more than just
    // the size of a `usize`.
    extra_data: usize,
}
```

This means that `&[T]` and `Box<[T]>` are actually two pointer-sized integers (i.e. 64-bit on 64-bit architectures and 32-bit on 32-bit architectures), one for the pointer to the first element and another for the length of the array. I’m going to explain a bit of groundwork here, to make sure that when we start invoking dark rites to twist and bend them you’re not totally lost.

So, if you’ve actually used Rust in real code, though, you might have noticed that this doesn’t mention `Vec<T>`. `Box<[T]>` is not a common type in Rust, as `Vec<T>` is far more flexible - it allows you to add more elements to the array at runtime without making a new array, whereas `Box<[T]>` does not. The reason for this difference is that `Box<[T]>` only stores the number of elements, and all those elements must be defined. `Vec<T>` works differently. It has a integer representing the amount of space it has, which can be more than the number of elements actually in the `Vec`. This means that it can allocate extra space that doesn’t contain defined elements, and then pushing to that Vec just writes into that space, without having to allocate a whole new array. Fine so far, although it means that `Vec` sadly requires three pointer-sized integers. Here’s a quick reference:

```rust
// This is invalid syntax in Rust of course, but it's just an illustration
// Size: 2 * size_of::<usize>()
struct &'a [T] {
    ptr: *const T,
    length: usize,
}

// Size: 2 * size_of::<usize>()
#[no_mangle]
pub fn dyn_as_ref<'a>(cow: &'a CursedCow<'_, dyn Foo>) -> &'a dyn Foo {
    &**cow
}

#[no_mangle]
pub fn dyn_to_cow<'a>(cow: CursedCow<'a, dyn Foo>) -> std::borrow::Cow<'a, dyn Foo> {
    cow.into()
}

#[no_mangle]
pub fn dyn_new_cow(cow: Box<dyn Foo>) -> Option<CursedCow<'static, dyn Foo>> {
    CursedCow::try_owned(cow)
}

#[repr(transparent)]
pub struct Test(u64);

impl ToOwned for Test {
    type Owned = Box<Test>;

    fn to_owned(&self) -> Self::Owned {
        Box::new(Test(self.0))
    }
}

#[no_mangle]
pub fn static_new_cow(cow: Box<Test>) -> Option<CursedCow<'static, Test>> {
    CursedCow::try_owned(cow)
}
struct Box<T> {
    ptr: *mut T,
    length: usize
}

// Size: 3 * size_of::<usize>()
struct Vec<T> {
    ptr: *mut T,
    length: usize,
    capacity: usize,
}
```

#quote(block: true)[
  *NOTE*: If you’re already familiar with the low-level details of Rust, you might have noticed some things I left out of the above types. Ignore them for now, I’ll get to it.
]

So there’s one other array type that I want to talk about, and it’s what the rest of this article will be focussed on. That type is #link("https://doc.rust-lang.org/std/borrow/enum.Cow.html")[`std::borrow::Cow`]. We’ll start by talking about `Cow<[T]>` and `Cow<str>`, although `Cow` is generic and works with other types, which we’ll get to later. We’ll mostly be talking about `Cow<[T]>` when it comes to implementation, since `Cow<str>` is the same as `Cow<[u8]>` at runtime - it just requires some extra invariants to be true about the bytes it contains and so it must be a separate type. `Cow<[T]>`/`Cow<str>` can be either a `&'a [T]`/`&'a str` or a `Vec<T>`/`String`. They’re useful in many cases, but one big one is in parsing. One example of where this might be useful is if you have a parser for a programming language that has strings that can have escape characters. You can have many strings simply be a reference into the original program text:

```rust
let a = "Hello, world";
//       ^----------^ Take a reference to these characters in the original program text
//                    and use it as the string value.
```

If you have an escape sequence, however, you need to allocate a new `String`, which is an owned string type, allocated on the heap, like `Box<[T]>` is an owned array type. This requests a block of memory which doesn’t have to follow the same lifetime rules as borrows - borrows must be created in an outer scope and passed inwards, but owned pointers can be created in an inner scope and passed back outwards, and in general are far more flexible, at the cost of inhibiting some optimisations and requiring computation to be done to create and destroy them. Once we’ve allocated our String, we write a version of the string from the program text into that buffer with all the escape sequences turned into the characters they represent. You can represent this with `Cow<str>` - either `Cow::Borrowed(some_string_reference)` if the string can be taken from the program text unchanged, or Cow::Owned(some_computed_string) if the string had to be edited. So how many bytes does `Cow<[T]>` take up? Well, it’s either a `Vec<T>` or a `&[T]`, so that means that we need enough space for `Vec<T>`, but we can reuse some of that space if it’s an `&[T]`, since it can only be one or the other. A `Vec<T>` takes up 3 pointer-size integers, and we can reuse 2 of those for the `&[T]`, so that means we only need 3 pointer-size integers. Except we also need to store a “tag” for whether it’s a `Vec<T>` or an `&[T]`. So that means that it’s 3 pointer-size integers, plus a single bit that can be either `0` for `Vec<T>` or `1` for `&[T]`. So for 64-bit, that’d be `3 * 64 + 1`, or `193`, right?

Unfortunately not. You can’t access a type at a bit offset, only at a byte offset. So that means that our size has to be a multiple of 8. Easy, we round it up and have 7 unused bits, right? Well still no. Integers have to be at an offset that is a multiple of its size. You can have a u64 stored at offset 8, 16, 24, 32, 40, etc, but not at an offset of 9, 10, 11, 12, and so forth. Well easy, we just see what the largest size of integer is that we have as a field of our type (in this case, pointer-size), and round our size up to that. So now our Cow type is 4 pointer-sizes in size, or twice the size of a `&[T]`. This doesn’t sound bad, but this adds up, and there are other downsides to this increase in size that I’ll get to later. We can confirm the size like so:

```rust
fn main() {
    // Prints 32 on 64-bit systems, which is 4 * 8, where 8 is the number of bytes in a 64-bit
    // integer
    println!("{}", std::mem::size_of::<std::borrow::Cow<[u8]>>());
}
```

= Act 1: Some Reasonable Optimisations

So what can we do to help? Well there are a few things. For a start, we can notice that if the vector has zero capacity, we can treat it identically to an empty array for most operations. Vectors with zero capacity don’t need their “drop code” ran, for example. So let’s make a version of `Vec` where it must always have a non-zero capacity.

```rust
use std::num::NonZeroUsize;

struct NonZeroCapVec<T> {
    ptr: *mut T,
    len: usize,
    cap: NonZeroUsize,
}
```

You’ll notice that we can still have a vector with no elements, as long as it has some space to store elements. So now, we can do our size calculations for `Cow<[T]>` again, replacing `Vec<T>` with `NonZeroCapVec<T>`. Again we notice that we `NonZeroCapVec` is 3 pointer sizes, and can reuse 2 pointer sizes of that to store the slice, except now the Rust compiler knows that it can use cap for both the tag and the capacity, where if cap is zero then it’s a slice, and if it’s non-zero then it’s a Vec. This is a useful trick. We can confirm that this type is now 3 pointer sizes like so:

```rust
enum CowArr<'a, T> {
    Borrowed(&'a [T]),
    Owned(NonZeroCapVec<T>),
}

fn main() {
    println!("{}", std::mem::size_of::<CowArr<u8>>());
}
```

Except no, sadly we actually can’t confirm this. At the time of writing Rust doesn’t yet optimise this correctly, and still reports that the size is 32. This is unfortunate, but until then we can implement this optimisation manually:

```rust
struct CowArr<'a, T> {
    // We can use `*mut` to store immutable pointers like `&T`, as long as we never derive an
    // `&mut T` from an `&T`
    ptr: *mut T,
    len: usize,
    cap: usize,
}
```

Then when we need to know if the value is owned or borrowed, we can simply check if cap is zero.

Rust has `NonZero` variants for all integers, plus a `NonNull<T>` pointer type which acts the same as a `*mut T`, except since Rust knows that it can’t be null, it can use a null pointer as an enum tag. Although Rust doesn’t optimise the size of the enum defined above, it will correctly use these `NonZero`/`NonNull` types in `Option`, which means that `Option<Box<[T]>>` is the same size as `Box<[T]>` - it can use a null pointer to mean None. So we can make our `CowArr` type work the same as `Box<[T]>` for Option, and let it use a null pointer to represent `None`, like so:

```rust
use std::ptr::NonNull;

struct CowArr<'a, T> {
    ptr: NonNull<T>,
    len: usize,
    cap: usize,
}
```

Again we can manually do the optimisation where we check `cap` for zero, but now Rust will automatically use a null pointer for `ptr` to mean `None` if we have an `Option<CowArr<T>>`.

```rust
fn main() {
    // Both of these print 24 on 64-bit systems, and 12 on 32-bit systems
    println!("{}", std::mem::size_of::<CowArr<u8>>());
    println!("{}", std::mem::size_of::<Option<CowArr<u8>>>());
}
```

Hm, except we’ve actually got more than just a size reduction here. To explain what I mean, we’re going to have to talk about assembly. For `std::borrow::Cow`, to do `as_ref` we first have to check whether we have a `Cow::Borrowed` or a `Cow::Owned`, then if we have the former we return the borrow we already have, and if we have the latter we do `<Vec<T>>::as_ref`, which is a pretty simple matter of taking the `ptr` and `len` from the vector and creating a slice with that `ptr` and `len`. The rest of the conversion is in the type system only, at runtime all doing `<Vec<T>>::as_ref` does is copy a pointer and a length from one place to another. Well with `CowArr` our code is simpler. The borrowed `ptr` and `len` is exactly the same as the owned `ptr` and `len`, the only difference is that if we have an owned value then `cap` is non-zero. That means that we don’t have to check `cap` at all, we only have to ensure the type system parts of the conversion are correct - essentially, we only need to ensure that we annotate lifetimes correctly. Then once the assembly is created, the type information is removed, and we’re left with an implementation of as_ref which is essentially a no-op. Well, the Rust Playground has a “Show Assembly” feature, so let’s use it:

```rust
use std::{
    borrow::Cow,
    ptr::NonNull
    marker::PhantomData,
};

pub struct CowArr<'a, T> {
    ptr: NonNull<T>,
    len: usize,
    cap: usize,
    // I omitted this before since it's just to silence the error that `'a` is unused.
    // There is more to `PhantomData` than just silencing errors, but it's out of scope
    // for this article.
    _marker: PhantomData<&'a T>,
}

impl<'a, T> CowArr<'a, T> {
    pub fn as_ref(&self) -> &[T] {
        unsafe { std::slice::from_raw_parts(self.ptr.as_ptr(), self.len) }
    }
}

#[no_mangle]
pub fn cow_as_ref<'a>(a: &'a Cow<'_, [u8]>) -> &'a [u8] {
    a.as_ref()
}

#[no_mangle]
pub fn cowarr_as_ref<'a>(a: &'a CowArr<'_, u8>) -> &'a [u8] {
    a.as_ref()
}
```

Clicking “Show Assembly” (in release mode, of course) shows us what this compiles to. Don’t worry, I know assembly can be scary so I’ve written comments:

```gas
;; For the standard library `Cow`...
cow_as_ref:
    ;; We only need to load the `ptr` once (good!)
    mov   rax, [rdi + 8]
    ;; Unfortunately, we check the tag to load the length
    cmp   [rdi], 1

    ;; This is a pointer to the length if we have a borrowed slice
    lea   rcx, [rdi + 16]

    ;; This is a pointer to the length if we have an owned vector
    lea   rdx, [rdi + 24]
    ;; We use `cmov`, which will overwrite the pointer to the borrowed
    ;; slice's length with the pointer to the owned vector's length if
    ;; our `Cow`'s tag shows that it is owned.
    cmove rcx, rdx

    ;; Then finally, we dereference this pointer-to-length to get the
    ;; actual length
    mov   rdx, [rcx]
    ret

;; For our `CowArr`
cowarr_as_ref:
    ;; We return the `ptr`
    mov rax, [rdi]
    ;; We return the `len`
    mov rdx, [rdi + 8]
    ;; That's it! We're done
    ret
```

Even if you don’t understand assembly, you can see that this is an improvement by the reduction in instruction count, if nothing else. It also reduces register pressure, although if you don’t know what that means then don’t worry - its effect is small enough that you don’t need to worry about it for now.

If you know anything about calling conventions, you might notice something a bit odd about that assembly code. We’ll get to it in due time, although not until after we pass through into the Forbidden Realms.

= Act 2: Stepping into the Forbidden Realms

So far, so simple. But we can do better, if we’re willing to add some restrictions. We can’t reduce the size of `ptr` since it’s not really possible to safely make many assumptions about the range of values a pointer can take, but the same can’t be said for `len` and `cap`. If we’re on a 64-bit system, using a 64-bit length and capacity allows us to store up to 18,446,744,073,709,551,615 elements, which I think we can agree that it’s unlikely for a single array to contain this many items in the majority of programs. In fact, it’s not even possible to create an array this large for anything other than u8 and other single-byte (or even smaller) types, since you’ll run out of address space long before that, not even mentioning that you’ll run out of memory on your computer long before you run out of address space. So let’s say that `len` and `cap` are both 32-bit on 64-bit systems. We’ll ignore 32-bit for now, on 32-bit systems we could choose to either make both `len` and `cap` 16-bit, or fall back to the implementation in the previous section. This choice isn’t really important for now, so I’ll focus on 64-bit. With 32-bit `len` and `cap` we can store arrays with up to 4,294,967,295 elements, which means, for example, that a single string can be up to 4Gb long. This is a restriction, certainly, it’s not unbelievable that your program would want to process larger strings, but the standard library Cow will always support that if you need it. If you don’t need that many elements, then this gives you a size reduction.

```rust
use std::ptr::NonNull;

struct CowArr<'a, T> {
    ptr: NonNull<T>,
    len: u32,
    cap: u32,
}

fn main() {
    // Both of these print 16 on 64-bit systems, and still print 12 on 32-bit systems
    println!("{}", std::mem::size_of::<CowArr<u8>>());
    println!("{}", std::mem::size_of::<Option<CowArr<u8>>>());
}
```

If you’re anything like me, saving 8 bytes like this is enough to make you cry with joy, but maybe we can do better. Now we get back to that “something a bit odd” that I mentioned above. See, when Rust passes a struct into a function or returns a struct from a function, it has a couple of ways to handle sharing the struct between the caller and the callee. If the struct is “small” (meaning two fields or less, with each field fitting into a single register), then the struct will be passed as an argument in registers, and returned in registers. Otherwise, the struct will be written to stack and a pointer to the struct will be passed to the callee. This is the “something a bit odd” that I mentioned before - many people assume that Rust _always_ passes structs with more than 1 element by pointer, and in fact until relatively recently it did. Now, if you’re as much of a rules-lawyer as me, you might notice a trick we can do here: although the struct above is not considered “small” by Rust, we can make a version of it that _is_ considered small. Let’s do that:

```rust
use std::ptr::NonNull;

struct CowArr<'a, T> {
    ptr: NonNull<T>,
    len_cap: u64,
}

const LEN_MASK: u64 = std::u32::MAX as u64;
const CAP_MASK: u64 = !LEN_MASK;
// We want the low 32 bits of `len_cap` to be `len`, and the high 32 bits to be `cap`,
// so we need to shift `cap` when reading and writing it.
const CAP_SHIFT: u64 = 32;

impl<'a, T> CowArr<'a, T> {
    pub fn as_ref(&self) -> &[T] {
        unsafe { std::slice::from_raw_parts(self.ptr.as_ptr(), self.len & LEN_MASK) }
    }
}
```

So sure, now we have a struct that’s the same size, but can be passed in registers, speeding up function calls that use it. Cool, but isn’t that & to mask the length going to add an additional cost? Well luckily for us, x86 has a way to mask the lower bits of a number for free! Since assembly is untyped, we can just pretend that our 64-bit number is a 32-bit number whenever we’re using it, and it’ll be the same as if we had masked the lower 32 bits. Additionally, we only have to allocate stack space and pass a pointer to the callee when we actually need to pass a reference to the `Cow`. If we pass an owned value, it’ll just stay in registers. Let’s see the assembly here to see what I mean:

```rust
struct CowArr3Fields<'a, T> {
    ptr: NonNull<T>,
    len: u32,
    cap: u32,
}

struct CowArr2Fields<'a, T> {
    ptr: NonNull<T>,
    len_cap: u64,
}

#[no_mangle]
pub fn cow_as_ref<'a>(a: &'a Cow<'_, [u8]>) -> &'a [u8] {
    a.as_ref()
}

#[no_mangle]
pub fn cowarr2fields_as_ref<'a>(a: &'a CowArr2Fields<'_, u8>) -> &'a [u8] {
    a.as_ref()
}
#[no_mangle]
pub fn cowarr3fields_as_ref<'a>(a: &'a CowArr3Fields<'_, u8>) -> &'a [u8] {
    a.as_ref()
}

#[no_mangle]
pub fn cow_noop(a: Cow<'_, [u8]>) -> Cow<'_, [u8]> {
    a
}

#[no_mangle]
pub fn cowarr2fields_noop(a: CowArr2Fields<'_, u8>) -> CowArr2Fields<'_, u8> {
    a
}

#[no_mangle]
pub fn cowarr3fields_noop(a: CowArr3Fields<'_, u8>) -> CowArr3Fields<'_, u8> {
    a
}
```

The assembly output of this looks like so:

```gas
cow_as_ref:
    mov   rax, [rdi + 8]
    cmp   [rdi], 1
    lea   rcx, [rdi + 16]
    lea   rdx, [rdi + 24]
    cmove rcx, rdx
    mov   rdx, [rcx]
    ret

cowarr2fields_as_ref:
    mov rax, [rdi]
    mov edx, [rdi + 8]
    ret

cowarr3fields_as_ref:
    mov rax, [rdi]
    mov edx, [rdi + 8]
    ret

cow_noop:
    mov    rax, rdi
    movups xmm0, [rsi]
    movups xmm1, [rsi + 16]
    movups [rdi + 16], xmm1
    movups [rdi], xmm0
    ret

cowarr2fields_noop:
    mov rdx, rsi
    mov rax, rdi
    ret

cowarr3fields_noop:
    mov    rax, rdi
    movups xmm0, [rsi]
    movups [rdi], xmm0
    ret
```

If you can read assembly, you can see that just returning an unmodified `Cow` requires some messing around with loading and storing data for all the structs apart from `CowArr2Fields`. If you can’t read assembly, then all you need to know is that the `[...]` square brackets is a memory access, and `cowarr2fields_noop` is the only function that doesn’t need them.

Ok, so we’ve optimised the `Cow` arrays about as much as we can. Now is when we start to invoke the Dark Magicks and risk the wrath of the Old Ones (you know, the Rust core team). Let’s make a “generic” optimised `Cow`, one that works with more than just arrays.

= Act 3: Forgive Me

So this is all well and good, but it’s _just not cursed enough_. It basically reimplements `Cow<[T]>` with a custom type that doesn’t work for `Cow<str>` - you have to write your own wrapper, maybe call it `CowStr`. Then repeat that for every type. No, we can do better. We can make a `CursedCow` that you works the same no matter if it’s `CursedCow<[T]>`, `CursedCow<str>`, or even `CursedCow<dyn Trait>`. That last one is where the code really starts to cause damage to the soul. If you find yourself cast into Hell one day, just know that it may be because you read this article. I think we can both agree that this is a fair and just punishment. Anyway, before we can truly damn ourselves, we need to lay down the groundwork and make the far-simpler `CursedCow<[T]>`/`CursedCow<str>` work. To make this work, we’ll need a trait.

```rust
pub unsafe trait Cursed<T: ?Sized>: Borrow<T> {
    fn borrowed(borowed: &T) -> Option<NonNull<T>>;
    fn owned(self) -> Option<NonNull<T>>;
    fn is_owned(ptr: NonNull<T>) -> bool;
    unsafe fn as_ref<'a>(ptr: NonNull<T>) -> &'a T;
    unsafe fn reconstruct(ptr: NonNull<T>) -> Self;
}
```

This trait is actually implemented for the owned variant, as opposed to `ToOwned` which is implemented for the borrowed variant. This is because many types may implement `ToOwned` pointing to the same type (you could imagine a slice wrapper where `ToOwned` still generates a `Vec`), but we still want to explicitly single out `Box` and other smart pointers. Implementing for the owned variant means that we don’t have to write any generic implementations with `impl<T> Cursed for T where ...`, which lets us circumvent the issue of overlapping implementations. The trait is unsafe, as it requires some invariants to be true about `Borrow`, and requires `borrowed`, `owned` and `is_owned` to be in agreement about what borrowed and owned pointers look like. Additionally, `as_ref` and `reconstruct` need to be unsafe functions because they should only ever have valid pointers passed into them.

So, let’s write the actual `CursedCow` struct now. So while in the previous sections we’ve been basically reimplementing Rust’s “fat pointer” system, we can’t do that any more if we want to support more than just arrays. We want to have a 2-pointer-width `CursedCow<T>` if `T` is unsized (such as `[T]`, `str` or `dyn Trait`) and a 1-pointer-width `CursedCow<T>` - just a regular pointer - if `T: Sized`. We do this by just using `NonNull<T>`, which is a fat pointer for unsized types, and letting the implementation of Cursed handle hiding the tag somewhere.

```rust
// `repr(transparent)` ensures that this struct is always treated exactly the same as `NonNull<T>`
// at runtime.
#[repr(transparent)]
pub struct CursedCow<'a, T>
where
    T: ?Sized + ToOwned,
    T::Owned: Cursed<T>,
{
    ptr: NonNull<T>,
    _marker: PhantomData<&'a T>,
}
```

Apart from the fact that you can’t explicitly match on its variants (or get a mutable reference to the internals, but there are ways around this) this is identical to `std::borrow::Cow` - you don’t do `CowArr<T>`, you just do `CursedCow<[T]>`, and this new `CursedCow` is 2 pointers wide. This is the same as before for 64-bit, although smaller on 32-bit at the cost of only allowing up to 65,535 elements.

Implementing the necessary methods for our new `CursedCow<T>` - methods to construct it from owned or borrowed data, a `Deref` implementation, `Drop` implementation, and so forth - is pretty easy so I’ll skip it, but you can see it in the full gist (linked at the end of the article).

The real work is done in the implementations of `Cursed` for `Vec<T>`, `String`, `Box<T>` and so forth. I’ll skip over the implementation for `String` for now since it’s basically the same as `Vec<T>`, but let’s start with an explanation of how we store all the information needed for a `CursedCow<[T]>` in a single `NonNull<[T]>`. You’ll see these constants `CAP_SHIFT`, `CAP_MASK` and `LEN_MASK` referenced in the following functions, so I’ll start by defining them here:

```rust
use std::mem;

const CAP_SHIFT: usize = (mem::size_of::<usize>() * 8) / 2;
const LEN_MASK: usize = usize::MAX >> CAP_SHIFT;
const CAP_MASK: usize = !LEN_MASK;
```

`CAP_SHIFT` is the amount you need to shift the `len` field of the `NonNull<[T]>` fat pointer to get the capacity that we’ve hidden in that field - i.e., the upper 32/16 bits (on 64- and 32-bit, respectively). `LEN_MASK` and `CAP_MASK` are the "masks" for these bits, so we can use bitwise & to only get the bits that represent the length or the capacity, respectively.

```rust
unsafe impl<T> Cursed<[T]> for Vec<T> {
    fn borrowed(ptr: &[T]) -> Option<NonNull<[T]>> {
        if ptr.len() & CAP_MASK != 0 {
            None
        } else {
            Some(NonNull::from(ptr))
        }
    }

    fn owned(self) -> Option<NonNull<[T]>> {
        // Fail if the capacity is too high
        if self.len() & CAP_MASK != 0 || self.capacity() & CAP_MASK != 0 {
            None
        } else {
            let mut this = mem::ManuallyDrop::new(self);
            unsafe {
                Some(NonNull::from(slice::from_raw_parts_mut(
                    this.as_mut_ptr(),
                    // This combines the length and capacity into a single `usize`
                    this.len() | (this.capacity() << CAP_SHIFT),
                )))
            }
        }
    }

    // ...snip...
}
```

So here you can see our checks that the length of the borrowed/owned values don’t exceed the amount we can represent in the reduced amount of space that we have. If we have too many elements or too much capacity, we return `None`, since there’s no way for us to store that. Although we could truncate the `len`, we can’t safely truncate the capacity without breaking some allocators, and truncating `len` would be a footgun. Otherwise, this looks pretty much the same as what we had before.

The rest of the trait is implemented essentially how you’d expect, and it looks pretty much the same as `CowArr` that we had before. This whole trait implementation looks basically exactly the same for `String`.

```rust
unsafe impl<T> Cursed<[T]> for Vec<T> {
    // ...snip...

    fn is_owned(ptr: NonNull<[T]>) -> bool {
        unsafe { ptr.as_ref() }.len() & CAP_MASK != 0
    }

    unsafe fn as_ref<'a>(ptr: NonNull<[T]>) -> &'a [T] {
        // Like before, this mask is essentially free because we can just treat `self.len`
        // like a smaller value, which acts the same as if we did the mask, instead of
        // actually masking.
        slice::from_raw_parts(ptr.as_ptr() as *const T, ptr.as_ref().len() & LEN_MASK)
    }

    unsafe fn reconstruct(ptr: NonNull<[T]>) -> Self {
        Vec::from_raw_parts(
            ptr.as_ptr() as *mut T,
            ptr.as_ref().len() & LEN_MASK,
            ptr.as_ref().len() >> CAP_SHIFT,
        )
    }
}
```

Well there we go, that’s it. Now our new `CursedCow<[T]>` acts like `CowArr<T>` automatically. It’s pretty cursed to hide the tag and capacity inside the `len` field of a slice, but we’re just getting started

Now we get to the jankiest part of all - `CursedCow<T>` for other values of `T`, and specifically `CursedCow<dyn Trait>`. Now, we can’t be generic over any `CursedCow<dyn Trait>`, since there’s no way to specify “some trait object” in the type system, but let’s say that if you’re using `CursedCow<dyn Trait>` for one reason or another then might have an implementation of `ToOwned` that has `Owned = Box<dyn Trait>`, since that’s the only way to have an owned trait object. That might look something like this:

```rust
trait MyCoolTrait {
    fn clone_boxed(&self) -> Box<Self>;

    // ... the rest of my cool functions...
}

impl ToOwned for dyn MyCoolTrait {
    type Owned = Box<dyn MyCoolTrait>;

    fn to_owned(&self) -> Self::ToOwned {
        self.clone_boxed()
    }
}
```

So, how do we store a tag representing the owned-or-borrowed tag in a `Box<T>`, since `Box` also uses the possibly-fat-pointer `NonNull<T>` internally? Well, there are a couple methods, both relying on the fact that not all the bits of pointers get used. For a start, most types have an alignment greater than 1. We mentioned alignment further up - `u64`s can only be at locations that are a multiple of `mem::size_of::<u64>()`, `u32`s can only be at locations that are a multiple of `mem::size_of::<u32>()`, and so forth. So because of this, we know that if the integer value of a pointer is odd then it must be invalid. We can use this to store a tag - if the pointer is odd then it’s owned (and we should subtract 1 to get the true pointer), if it’s even then it’s just a normal borrowed pointer. That would be a pretty cursed implementation of `Cow`, for sure, but we can’t implement it generically, and we can’t implement it for `dyn Trait` since that would lead to weird bugs where `Cow<dyn Trait>` was fine for most types, but doesn’t work if the implementation of your trait happens to have a size of 1, and you wouldn’t know that until it explodes at runtime.

Another possibility is that Rust goes out of its way to make sure that pointers can’t overflow an isize, since this means that adding two pointers together will never overflow. As far as I know this isn’t a hard guarantee, but certainly on 64-bit x86 it’s not even possible on any hardware that exists in the real world to have a pointer larger than 63 bits, so that 64th bit will always be 0. We can take advantage of that, and if we get given a pointer that happens to have the top bit set, we can just return `None`, the same as if we get given a `&[T]`/`Vec<T>` that’s too large to store. Now, manually manipulating the pointer field of a fat pointer isn’t allowed in Rust - we can do arithmetic on a normal, "thin" pointer, but there’s no way to mutate the pointer field of a fat pointer. However, we can work around this doing a pointer-to-pointer cast, which is undefined behaviour in C but not in Rust. This is wildly unsafe, and we need to be extremely careful to make it work at all, let alone make it work in a way that won’t immediately cause undefined behaviour. Here’s the cursed function at the heart of it all, which allows us to treat the data pointer of a fat pointer as if it’s a usize, and so allows us to manipulate its bits directly.

```rust
fn update_as_usize<O, F: FnOnce(&mut usize) -> O, T: ?Sized>(ptr: &mut *mut T, func: F) -> O {
    unsafe {
        // Here's where we invoke the darkest of dark magic, explanation below.
        let ptr_as_bytes = mem::transmute::<&mut *mut T, &mut usize>(ptr);
        // Since this is dark magic, we make sure that we explode if our
        // assumptions are wrong.
        assert_eq!(*ptr_as_bytes, *ptr as *mut u8 as usize);
        func(ptr_as_bytes)
    }
}
```

The way this works assumes that the layout of the fat pointer has the data pointer first. Essentially, the fat pointer for `NonNull<dyn Trait>` looks like this, and in fact you can find this exact struct in `std::raw::TraitObject`:

```rust
struct TraitObject {
    data: *mut (),
    vtable: *mut (),
}
```

However, even with nightly Rust we can’t use `std::raw::TraitObject`, since it doesn’t work for any fat pointer, only `dyn Trait`, and as mentioned before we can’t be generic over "any trait object". So we have to make the further assumption that not only do trait objects have the data pointer first, but all fat pointers have the data pointer first. That’s what the `assert_eq` in `update_as_usize` does: it uses Rust’s native ability to convert the pointer to a thin `*mut u8` to make sure that our mutable pointer-to-`usize` is pointing at the right data. This is wildly unsafe, and although it’s likely to work for the forseeable future for all the fat pointers that Rust supports, there’s no guarantee that this will be the case, and if this ever becomes incorrect in a way that the `assert_eq` doesn’t catch then you’ll get undefined behaviour. So for now we’ll keep using this, because it works, but I want to stress that you should _*NOT USE THIS IN REAL SOFTWARE*_, unless you want to get fired and deserve it.

Anyway, since this works just fine for now, let’s explore these cursed realms a little further, shall we?

```rust
// The mask for the actual pointer
const PTR_MASK: usize = usize::MAX >> 1;
// The mask for just the "is owned" tag
const TAG_MASK: usize = !PTR_MASK;

unsafe impl<T: ?Sized> Cursed<T> for Box<T> {
    fn borrowed(ptr: &T) -> Option<NonNull<T>> {
        // We use `Self::is_owned` here to avoid duplicating information. You can think of this
        // in this context as expressing "if we _would think_ that `ptr` was owned"
        if Self::is_owned(NonNull::from(ptr)) {
            None
        } else {
            Some(NonNull::from(ptr))
        }
    }

    fn owned(self) -> Option<NonNull<T>> {
        let mut this = mem::ManuallyDrop::new(self);
        let original_ptr = &mut **this as *mut T;
        let mut ptr = original_ptr;

        update_as_usize(&mut ptr, |p| *p |= TAG_MASK);

        unsafe {
            if Self::is_owned(NonNull::new_unchecked(original_ptr)) {
                this.into_inner();
                None
            } else {
                Some(NonNull::new_unchecked(ptr))
            }
        }
    }

    fn is_owned(ptr: NonNull<T>) -> bool {
        ptr.as_ptr() as *mut u8 as usize & TAG_MASK != 0
    }

    unsafe fn as_ref<'a>(ptr: NonNull<T>) -> &'a T {
        let mut ptr = ptr.as_ptr();
        update_as_usize(&mut ptr, |p| *p &= PTR_MASK);
        &*ptr
    }

    unsafe fn reconstruct(ptr: NonNull<T>) -> Self {
        let mut ptr = ptr.as_ptr();
        update_as_usize(&mut ptr, |p| *p &= PTR_MASK);
        Box::from_raw(ptr)
    }
}
```

So there we go, apart from the implementations of the traits you’d expect from a `Cow` implementation, which should be fairly self-explanatory, and a `Drop` implementation, which is also pretty simple, this is more-or-less a fully-working drop-in replacement for `std::borrow::Cow`. Finally, let’s see what the codegen looks like for this implementation of `Cursed` for `Box<T>`. You can just take my word for it that `CursedCow<[T]>` generates exactly the same code as `CowArr<T>`. Let’s write the code for a couple of different scenarios that we want to test the codegen for - first for fat pointers, and then for thin pointers (if for some reason you had a `ToOwned` implementation for a non-dynamically-sized type that still used Box when it’s owned).

```rust
#[no_mangle]
pub fn dyn_as_ref<'a>(cow: &'a CursedCow<'_, dyn Foo>) -> &'a dyn Foo {
    &**cow
}

#[no_mangle]
pub fn dyn_to_cow<'a>(cow: CursedCow<'a, dyn Foo>) -> std::borrow::Cow<'a, dyn Foo> {
    cow.into()
}

#[no_mangle]
pub fn dyn_new_cow(cow: Box<dyn Foo>) -> Option<CursedCow<'static, dyn Foo>> {
    CursedCow::try_owned(cow)
}

#[repr(transparent)]
pub struct Test(u64);

impl ToOwned for Test {
    type Owned = Box<Test>;

    fn to_owned(&self) -> Self::Owned {
        Box::new(Test(self.0))
    }
}

#[no_mangle]
pub fn static_new_cow(cow: Box<Test>) -> Option<CursedCow<'static, Test>> {
    CursedCow::try_owned(cow)
}
```

The code made by these functions is pretty amazingly minimal, and almost entirely avoids using the stack - keeping most values in registers. I won’t explain this assembly fully, but it’s here for completeness:

```gas
dyn_as_ref:
    mov    rdx, [rdi + 8]
    movabs rax, 9223372036854775807
    and    rax, [rdi]
    ret

dyn_to_cow:
    mov    rax, rdi
    movabs rcx, 9223372036854775807
    and    rcx, rsi
    test   rsi, rsi
    jns    .is_ref
    mov    esi, 1
    mov    [rax + 8], rcx
    mov    [rax + 16], rdx
    mov    [rax], rsi
    ret
.is_ref:
    xor    esi, esi
    mov    [rax + 8], rcx
    mov    [rax + 16], rdx
    mov    [rax], rsi
    ret

dyn_new_cow:
    mov    rdx, rsi
    movabs rcx, -9223372036854775808
    or     rcx, rdi
    xor    eax, eax
    test   rdi, rdi
    cmovns rax, rcx
    ret

static_new_cow:
    movabs rcx, -9223372036854775808
    or     rcx, rdi
    xor    eax, eax
    test   rdi, rdi
    cmovns rax, rcx
    ret
```

Anyway, if you want to try this out then I recommend the #link("https://crates.io/crates/beef/")[`beef` crate], which acts as a drop- in replacement for `std::borrow::Cow` for most cases. It’s written by my colleague and friend, and this article came about due to discussions about how to optimise that crate for the usecase of parsing JSON. It doesn’t include our incredibly sketchy `dyn Trait` implementation, thank god. There’s also the simpler #link("https://crates.io/crates/cowvec/")[`cowvec` crate], which is my earlier implementation, roughly equivalent to the code we had at the end of Act 2. I’d only recommend `beef` over `cowvec` because `cowvec` doesn’t act as a drop-in replacement as it has a different signature to `std::borrow::Cow`. Well, that and the fact that `beef` is clearly the far better name.

The JSON-parsing crate `simdjson-rs` actually integrated `beef` recently, and you can see the improvements to throughput that they saw just from switching out their `Cow` implementation in the integration PR.

Now if you don’t mind, I’m going to go seek the advice of a priest.

#quote(block: true)[
  *NOTE*: This article originally contained an extended section about how to extend this implementation to support inlining data, but this was considered too cursed for the eyes of mere mortals. Perhaps after I’ve thoroughly cleansed myself with holy water, I may be able to bring myself to write an additional article detailing how to implement this within our existing framework.
]
