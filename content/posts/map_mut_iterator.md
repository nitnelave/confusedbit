---
title: "Teaching the Rust Borrow Checker"
date: 2023-01-19T09:07:16+01:00
lastmod: 2023-01-20T09:57:16+01:00
---

# Setup

While I was doing the [Advent of Code 2022](https://adventofcode.com/2022), I
stumbled upon a pattern that should be expressible in safe Rust, but is beyond
the understanding of the borrow checker. Although its use cases are probably
rather niche, I still found it potentially useful. Anyway, it's a good exercise
to understand more about the borrow checker, by seeing its limitations.

The problem in question was [day 23](https://adventofcode.com/2022/day/23). I'm
going to greatly simplify the problem for the sake of the exercise:
 - You have a potentially infinite array (in both directions) of elves.
 - Every turn, each elf checks whether the space to the right is free, in which
   case they decide to jump to the right. Otherwise, they do the same to the
   left.
 - Once each elf has decided, they jump to their destination. In case of
   conflict (two elves landing in the same spot), both elves stay where they
   are.

There are of course many ways to model this problem. Because I was (wrongly)
feeling particularly smart at the time, I decided to use a hash map to store
only the elves, rather than have an array that is resizeable in both
directions.[^1]

[^1]: I ended up with just a very big array with plenty of space, and no dynamic
growth needed. It was much faster. But *still*, given the right starting
conditions, the map could have been the right choice!

For reasons that mostly pertain to the exercise, we'll store the decision of
where to jump in each elf in the map[^2]:

[^2]: There are better ways to model the problem, including separating the
mutable state from the position of the elves and producing a map of `Position`
to `Position` representing the jumps. Having the inverse map would be even more
helpful to detect collisions, but that's not the point here.

```rust
type Position = i64;
struct Elf {
  will_jump_to: Option<Position>,
}
```

This leads us to having an interesting access pattern for the map: we want to
iterate the map and update the values based on the other keys in the map. In
other words, we want to write something like:

```rust
fn update_jumps(map: &mut HashMap<Position, Elf>) {
  for (position, mut elf) in map.iter_mut() {
    elf.will_jump_to = if map.contains_key(&(position + 1)) {
      Some(position + 1)
    } else if map.contains_key(&(position - 1)) {
      Some(position - 1)
    } else {
      None
    };
  }
}
```

Naively writing that will make us run into the borrow checker: we're holding a
`&mut` reference to `map` (when we call `.iter_mut()`), but we're borrowing it
again in `map.contains_key`!

```
error[E0502]: cannot borrow `*map` as immutable because it is also borrowed as mutable
 --> src/main.rs:8:27
  |
7 |   for (position, mut elf) in map.iter_mut() {
  |                              --------------
  |                              |
  |                              mutable borrow occurs here
  |                              mutable borrow later used here
8 |     elf.will_jump_to = if map.contains_key(&(position + 1)) {
  |                           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ immutable borrow occurs here
```

Now, there are various ways to solve this problem (see [What can I do
instead](#ps-what-can-i-do-instead)). But let's assume that we're stubborn and
really want to have this _specific_ access pattern, since it's convenient to
write and we're pretty convinced it's safe.

# Part 1: in which he's wrong

First of all: is it actually safe? We need to make sure that there is no memory
that is accessed both in a mutable and immutable way at the same time. At a
high level, we have a mutable borrow of the `map` at the same time as an
immutable borrow of it, so it would be unsafe. However, the only mutable part of
`map` that we're accessing is the values, and the only immutable part is the
keys (and the structure of the map). The two do not overlap, so the access
pattern should be safe.

**OR SO IT WOULD SEEM!** Actually, the rules are that you cannot _form a
reference_ so that there are both a mutable and an immutable one pointing to
the same memory, _regardless of whether you access it or not_. That restricts
us much more than before: we have to look at the implementation of the map to
see whether we can iterate on the keys (or call `contains_key`) without _ever
forming a reference to the value_! However, `HashMap` is implemented on top of
`hashbrown::hash_map`, which underneath is basically a
`hashbrown::hash_set<(Key, Value)>`. Notably, iterating over the keys is just
iterating over the `&(k, v)` and then dropping the value: we have a reference to
the tuple, so a reference to the value.

The equivalent code could look like that:

```rust
for (position, mut elf) in map.iter_mut() {
  // We have a mutable reference to the value `elf`.

  // Check if map.contains(&(position + 1))
  for key_value in map.iter() {
    let key = &key_value.0;
    if key == position + 1 {
      // do the thing.
    }
  }
}
```

The problem is that when we have a reference to `key_value`, the tuple, we have
a reference to the entire memory pointed to by `key_value`, i.e. to the memory
of `key` and the memory of `value`. As such, the compiler can make the
assumption that _no one has a mutable reference to that memory_, which is not
true. Given that it is undefined behavior, the compiler would be well within its
right to "deduce" that since it iterates immutably over all the key-values of
the map, the entire map is immutable. Any code that changes anything in that map
cannot be called, so there are no side effects to that function (since it
doesn't return anything). The function can thus be compiled to:

```rust
fn update_jumps(map: &mut HashMap<Position, Elf>) {}
```

The compiler (rustc) doesn't actually (currenty) do that, but it _could_, that's
the point of undefined behavior. It might work right now, but later a compiler
update might implement a smarter optimization that breaks your code. Or
compiling with gccrs might not work. Or the tests could pass in debug mode, but
your prod app could break in release mode. Who knows what might happen?[^safe]

[^safe]: I haven't actually run into problems with this code, but it might
  depend on the follow-up access pattern, the optimization level, the
  CPU architecture or the phase of the moon. You're in uncharted territory here,
  don't blame me if it crashes.

# Part 2: in which he uses an imaginary implementation

Now, for the rest of this article, I'm going to assume a different `HashMap`
implementation, one that is implemented as a `hash_set<(Key, Box<Value>)>` or a
`hash_set<(Key, value_index)>` + a `Vec<Value>` or something like that.[^box]
Otherwise that's a fairly short blog post.

[^box]: The key difference here is that iterating over the key doesn't iterate
  over the values at the same time, because of the indirection. It's not
  compatible with the API of `HashMap`, since it provides an iterator over
  `&(Key, Value)` which is exactly the thing we want to avoid. But hey, we're in
  fantasy land, we can come up with the API we want!

{{<warning>}}
Everything that follows is **unsafe** and **unsound** with the standard
collection's `HashMap`.
{{</warning>}}

So, now that we know that it's Safe&trade;, how do we explain that to the compiler?
Well, we have to use `unsafe`. We can naively get a double reference to `map`,
one mutable and one not:

```rust
fn update_jumps(map: &mut MyHashMap<Position, Elf>) {
  for (position, mut elf) in map.iter_mut() {
    let new_jump = if map.contains_key(&(position + 1)) {
      Some(position + 1)
    } else if map.contains_key(&(position - 1)) {
      Some(position - 1)
    } else {
      None
    };
    let mut mutable_elf = unsafe { &*(elf as *Elf) };
    mutable_elf.will_jump_to = new_jump;
  }
}
```

That looks like it would work, but it is unsound: we have both a reference to
`elf` and to `mut elf` at the same time, and in general transmuting from `&T` to
`&mut T` is _never_ sound.

*EDIT: Thanks to /u/A1oso for pointing that out!*

What we need is to build a _safe_ interface for the pattern, so that it
cannot be misused.

What do we need?
 - An interface to access the immutable part of the map, i.e. the structure and
   the keys.
 - An interface to access the mutable part of the map, i.e. the values.
 - No way to access anything that will change the structure (e.g. `insert`, `remove`).
 - No way to access two arbitrary values mutably at the same time.

The last one is particularly tricky, we'll see later: it's important because if
we have a _mutable_ reference to a value, we shouldn't be able to get an
_immutable_ reference to the same value, unless we can guarantee that it's not
the same value (if you need this, you probably want a `HashMap<Key,
RefCell<Value>>`).

# Part 3: in which he heroically prevents future bugs

So, let's build the first interface:

```rust
pub struct ContainerView<'map, Key, Value> {
    // Immutable reference to the map.
    map: &'map MyHashMap<Key, Value>,
}
```

To note here: since we're holding a reference to the map, we need to say how
long the reference will be valid for, so the `ContainerView` has a lifetime
parameter `'map`: this is used in the reference declaration `map: &'map
MyHashMap<Key, Value>` to say that the field is a reference that is only valid for
the lifetime `'map`. As a result, the borrow checker knows that this struct
is limited to that lifetime (for instance, it cannot escape the function and
outlive the `map`).

Now we can implement some member functions:

```rust
impl<'map, Key: Hash + Eq, Value> ContainerView<'map, Key, Value> {
    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn contains_key(&self, k: &Key) -> bool {
        self.map.contains_key(k)
    }

    pub fn keys(&self) -> Keys<'_, Key, Value> {
        self.map.keys()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}
```

We're not providing access to anything that can access the keys or modify the
structure here.

And the second interface:

```rust
pub struct MutMapValueAccessor<'map, Key, Value> {
    map: &'map MyHashMap<Key, Value>,
}
```

Same as the first one. Note that we can't have that reference be `mut` since we
already have a non-`mut` reference to the map.

```rust
impl<'map, Key: Hash + Eq, Value> MutMapValueAccessor<'map, Key, Value> {
    fn cast_value_to_mut(val: &UnsafeCell<Value>) -> &mut Value {
        unsafe { &mut *val.get() }
    }

    pub fn get_mut(&mut self, k: &Key) -> Option<&mut Value> {
        self.map.unsafe_get(k).map(cast_value_to_mut)
    }

    pub fn values_mut(&mut self) -> ValuesMut<'_, Key, Value> {
        self.map.unsafe_values().map(cast_value_to_mut)
    }

    pub fn iter_mut(&mut self) -> IterMut<'_, Key, Value> {
        self.map.unsafe_iter().map(|(k, v)| (k, cast_value_to_mut(v)))
    }
}
```

*EDIT: In a previous version of this article, `cast_value_to_mut` took a
`&Value` as argument, and cast it to `&mut Value`. This is **never sound**, we
need to use `UnsafeCell` instead. Our imaginary `MyHashMap` implementation
returns `UnsafeCell`s in `unsafe_get`, `unsafe_values` and `unsafe_iter`. Those
function should not be public, of course. That has to be built in to the type,
the map needs to store the values wrapped in `UnsafeCell`. As such, you can't
just implement that on top of a standard container.*

We can provide `get_mut`: giving access to one mutable value at a time is okay.
Since it borrows `self` as mut, the lifetime guarantees that we're not going to
have two mutable borrows at once (like the `HashMap` interface).
Note that we only convert into a mutable reference at the very end, when the
reference only covers a value. Similarly, implementing `values_mut` and
`iter_mut` is just a map over the `MyHashMap` iterator. For `iter_mut`, we're
also providing immutable references to keys. We can also get them from the
`ContainerView`, but having multiple immutable references is okay.

Putting it all together, we can limit our little bit of `unsafe` to a safe
interface:

```rust
pub fn make_mut_accessor<Key: Hash + Eq, Value>(
    map: &mut MyHashMap<Key, Value>,
) -> (
    ContainerView<'_, Key, Value>,
    MutMapValueAccessor<'_, Key, Value>,
) {
    (ContainerView { map }, MutMapValueAccessor { map })
}
```

This creates the two views of the map, mutable values and immutable structure.
Note that we still take a `&mut map`, even though we're only storing `&map`:
semantically, the accessor has a mutable access, so we want to guarantee that
no other references exist. In particular, the `MutMapValueAccessor` should not
be publicly constructible, since it allows you to modify the values through an
immutable reference.

Now we can re-write our initial function:

```rust
fn update_jumps(map: &mut MyHashMap<Position, Elf>) {
  let (container_view, mut value_accessor) = make_mut_accessor(map);
  for (position, mut elf) in value_accessor.iter_mut() {
    elf.will_jump_to = if container_view.contains_key(&(position + 1)) {
      Some(position + 1)
    } else if container_view.contains_key(&(position - 1)) {
      Some(position - 1)
    } else {
      None
    };
  }
}
```

And now the bonus questions:
 - Can we implement `Clone` for `ContainerView`?[^clone_view] For
   `MutMapValueAccessor`?[^clone_accessor]
[^clone_view]: Yes, we can just copy the reference. It's okay to have several immutable
  references to the map.

[^clone_accessor]: No, that would lead to multiple _mutable_ references to the map.

 - Can we derive `Debug` for `ContainerView`? What about `PartialEq`?[^debug]

[^debug]: No for both, since that would require at some point to have an immutable
  reference to a value, and we already have a mutable one in
  `MutMapValueAccessor`. Of course, you could always _implement_ `Debug` or
  `PartialEq`, but you'd have to be careful to never use the values of the map.

# Conclusion

As you saw, it's very easy to lure yourself through rational reasoning into an
actually unsound situation that might lead to bugs way down the line. Whenever
you want to go against the borrow checker, it's best to either suck it up and
come up with a different, safe design, or really ask an expert about it. In
this case, the good folks at the Rust Discord and on /r/rust helped me see the
error of my ways, and there were several mistakes in early drafts of this
article.

And if you _do_ end up using `unsafe`, make sure you install as many barriers
as possible to avoid any misuse due to invalidated assumptions.

# P.S.: What can I do instead?

In this situation, it depends on your constraints:
 - If you have no control over the function signature (fixed API), you can copy
   the keys: `let positions = map.keys().collect<HashSet<_>>();`. Then you can
   use `contains` on the `positions` instead of the `map`.
 - You can also create a new map instead of updating the old one,
   functional-programming-style.
 - If you control the API and it's an internal data structure, the cleanest code
   might be to change the map to be `HashMap<Position, RefCell<Elf>>`. Or if
   you're recalculating the entire `Elf` every time, `HashMap<Position,
   Cell<Elf>>` avoids runtime borrow checks (at the cost of a clunkier API).
 - A more generic approach that fits many Rust borrow checker issues is to add a
   layer of indirection through an index: you decouple the mapping from position
   to elf and the elf storage by having a `HashMap<Position, usize>` and a
   `Vec<Elf>` (or `HashMap<usize, Elf>` if insertions/deletions are
   problematic). This is fairly typical for graphs.
 - If you don't want to compromise on anything but you still control the API,
   your only option might be to use `UnsafeCell` to wrap the values of your map.
   But then it's up to you to _guarantee_ that the Rust assumptions are upheld,
   in particular that you don't have a mutable and immutable reference to the
   same thing alive at the same time.
 - Finally, sometimes having a long hard look at your domain causes you to
   completely rethink your data structure! For this problem, I ended up using a
   Big Enough&trade; pre-allocated `Vec<Option<Elf>>` for every possible
   `Position`. That made the code run much faster since the memory access
   pattern was more localized, more predictable, and much less time was spent
   hashing integers over and over again.

</body>
