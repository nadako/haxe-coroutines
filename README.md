# !!! THIS IS A WORK-IN-PROGRESS MATERIAL, NOTHING SET IN STONE AND EVERYTHING IS TO BE DISCUSSED. THIS DOCUMENT WILL BE EDITED AND CHANGED OFTEN !!!

## This is heavily inspired by [Kotlin coroutines design](https://github.com/Kotlin/KEEP/blob/master/proposals/coroutines.md), reduced and adapted for Haxe.

# Coroutines for Haxe

* Proposal: [HXP-NNNN](NNNN-coroutines.md)
* Author: [Dan Korostelev](https://github.com/nadako)

## Introduction

The goal of this proposal is to provide a mechanism to have suspendable/resumable functions a.k.a. [coroutines](https://en.wikipedia.org/wiki/Coroutine) in Haxe in a way they can be successfully used on every Haxe target for a lot of use cases in different environments.

This is a huge feature that requires a lot of thought and discussion, so this document will be structured a bit differently than a typical Haxe evolution proposal.

The concept of coroutines covers features known in some languages as "async/await" and "generators/yield". We propose a generic implementation of coroutines in Haxe compiler, that can be used as a base for both of the aforementioned features as well as cover domain-specific use cases with minimal syntatic and run-time overhead.

## Motivation

As most programming languages, Haxe has clear syntax for describing sequences of actions: function calls, loops, conditions, etc. A simple user interaction can look like this:

```haxe
function greet() {
  speak("What's your name?");
  var name = listen();
  speak('Nice to meet you, $name!');
  wait(1000);
  explode();
}
```

This is very concise and easy to both write and read, however code like this is only possible if used functions work synchronously and return their result immediately.

This is, of course, NOT the case in modern programming: games are full of simultaneously moving characters and animations, servers doing thousands of I/O operations, etc. So nowadays we write asynchronous code using callback techniques in one way or another.

The most obvious way to rewrite our `greet` function so it works in asynchronous world, would be to use callbacks, like this:

```haxe
function greet() {
  speak("What's your name?", function() {
    listen(function(name) {
      speak('Nice to meet you, $name!', function() {
        wait(1000, explode);
      });
    });
  });
}
```

This code is larger and much harder to follow. Imagine we also had to have a loop with asynchronous calls in the middle, as well as do some complex error handling, and you'll end up with what is called "callback hell".

To mitigate that, we introduce abstractions over asynchronous computations, such as promises, tasks, futures, etc. If we e.g. use JavaScript promises combined with some chaining and identation tricks, we can make our code look a bit better:

```haxe
function greet() {
  speak("What's your name?")
  .then(_ -> listen())
  .then(name -> speak('Nice to meet you, $name!'))
  .then(_ -> wait(1000))
  .then(_ -> explode());
}
```

Implementations of used functions, like `speak` encapsulate the asyncronous operation in a promise object that follows defined protocol that allows for composition so we manage not to lose our sanity and keep asynchronous computations under control.

Our ultimate goal when writing application, however, is still to describe a sequence of operations, even if they are asynchronous. So it would be very nice to be able to use standard language constructs designed for that without introducing specific abstractions and writing additional code.

This is where coroutines come into play. Conceptually, coroutine is a function that can suspend its execution, yield control to other code to be resumed later. With that in mind, using coroutines we can describe algorithms using standard Haxe language constructs, so an asynchronous version of our `greet` function would look just the same:

```haxe
function greet() {
  speak("What's your name?");
  var name = listen();
  speak('Nice to meet you, $name!');
  wait(1000);
  explode();
}
```

## Difference from async/await/yield

As we talked in the previous section, several popular languages provide abstractions over asynchronous operations, e.g. `Promise` in JavaScript or `Task` in .NET, which nowadays come with syntatic sugar for working with them in the form of `async` and `await` keywords. What these keywords do is basically transform the function into a coroutine with an explicit syntax. Let's take a look at the C# example:

```cs
extern Task<string> LoadString();

async Task<Data> LoadData(string url)
{
  string source = await LoadString(url);
  return ParseData(source);
}
```

The `async` modifier tells the compiler that this function represents a resumable asynchronous computation and its body should be transformed into a `Task<Data>` object. The `await` keyword marks that the computation should be suspended in order to await the completion of an operation, represented by the `Task<string>` object returned by the `LoadString` function and get the result from it. As one can guess, the `Task` is the common protocol for asynchronous computations that glues the machinery together.

Another coroutine-generating language construct available in both C# and modern JavaScript is the `yield` keyword, designed to provide means of easily writing lazily computed (possibly infinite) sequences, e.g.:

```cs
IEnumerable<int> NaturalNumbers()
{
  int i = 0;
  while (true)
  {
    yield return i;
    i++;
  }
}
```

This functions generates a `IEnumerable` object instead of `Task` and the `yield` keyword marks the suspension point of a computation that yields control, similar to `await` in the previous example. Unlike `await`, however, it has a different meaning in that it doesn't await an asynchronous task to complete, but returns a value, hence the `yield return` keyword combination.

This approach is quite solid: thanks to standard interfaces and explicit syntax, it allows for very clear and readable asynchronous and generator code.

---

This document, however, proposes a very generic lower-level coroutines implementation that doesn't enforce specific task abstractions or explicit await/yield syntax. At first, this may sound unwise concerning portability and readability, so I'll try explaining why it's actually more portable, flexible and readable in my opinion.

---

Haxe by its nature is designed to be used in a lot of different run-time environments, together with different APIs provided by target platforms and is suitable for various kinds of projects.

With that in mind, when it comes to using coroutines, for the sake of better interoperability it should ideally support target-native promise/future/task abstraction types, as well as plain callback-based API, found in e.g. Node.js. Regarding generators, it's the same: while Haxe has the standard `Iterator` protocol, one might not want to use it in a specific application for performance or interop reasons. Besides async operations and generators there are other use-cases for coroutines, like Go-like concurrency and DSLs for easily describing interaction scenarios and animations.

So one of the requirement for the coroutines feature is to be able to easily tell the compiler when the coroutine must be suspended and, more importantly, how it's resumed and how to extract the result of a suspending call without wrapping every suspending call in a Haxe-specific promise-like object.

---

Another difference is the lack of the special `await` and `yield` keywords in the proposed design. While the explicitness helps a lot with figuring out the control flow of a mostly-synchronous function that does some async calls, like the `LoadData` example above, there can be situations where it's not desired at all and becomes more of a visual clutter.

Let's get back to our very first synchronous code example:

```haxe
function greet() {
  speak("What's your name?");
  var name = listen();
  speak('Nice to meet you, $name!');
  wait(1000);
  explode();
}
```

This is actually a fairly realistic NPC interaction scenario snippet for a game. And as we said at the beginning of this document, environments and animations in modern games are very rich and we'd like this scenario to be shown nicely animated and in parallel with different events happening in the game. Because of that, all the functions used in this scenario must be asynchronous. With mandatory `await` keyword we would have to prefix EVERY call with it, making the code more cluttered and thus less readable:

```js
async function greet() {
  await speak("What's your name?");
  var name = await listen();
  await speak('Nice to meet you, $name!');
  await wait(1000);
  await explode();
}
```

Code like this is not uncommon in languages that support coroutines through explicit `yield` or `await` keywords, because people try to implement kind of mini-DSLs for scripting animations and interaction behaviours for games and UIs. However, in these particular DSL use cases, explicitly marking the function as a coroutine would be enough for readability.

In general, I would say that when writing high-level application business-logic, whether the algorithm is synchronous or asynchronous is not that important, while the clearness and expressiveness of the code that describes it is a priority.

Another use case where explicit `await` would be unwanted is Go-style channel-powered concurrency where basically every function is a coroutine and can be started in a different thread (or not), managed implicitly at run-time.

---

So, if we consider all (or at least most of) possible use cases, our goal would be to have a very generic coroutines with opt-in explicitness and support for any given async/generator primitives and conventions with minimal to no overhead.

Instead of being baked into language, explicit `await` syntax could thus be achieved through a normal user-defined suspending function that takes a task/promise or a partially applied callback-expecting function as its argument, e.g:

```haxe
suspend function loadJson(url:String):MyData {
  var json = await(load(url)); // could also be load(url).await() extension function
  return Json.parse(json);
}
```

## Detailed design

Now when we talked about what coroutines are, what problems are they supposed to solve and how our approach differs from async/await/yield, let's describe the actual proposed design for coroutines in Haxe.

Since coroutine functions have to be known by the compiler in order to be transformed into pausable re-entrant computation objects, we mark such functions with a special modifier. The simpliest way is to use a metadata, like `@:coro` or `@:suspend` (Kotlin-like). Another option is to introduce a proper keyword for that so it can be used in the line with other function modifiers (public, static, inline, etc). In examples below, I'll use `suspend` keyword as the modifier.

When a coroutine function contains a call to another coroutine function, its execution is being paused until the called function resumes it. Let's call it pause point or suspension point. For example:

```haxe
suspend function listen():String;

suspend function greet() {
  var name = listen(); // execution is suspended here
  speak('Hello, $name!');
}
```

This is basically how coroutines are supposed to be used by this design - not much different from normal functions. They are, of course, different with regard to actual implementation integration in the non-coroutine environement.

### Continuations

To make suspending functions work together, we only need a very minimal abstraction for a thing called `continuation`. Simply speaking, it represents the rest of computation to be resumed when appropriate. We define it like this:

```haxe
interface Continuation<T> {
  /** Resume execution, passing the result of a suspending call */
  function resume(result:T):Void;

  /** Resume execution with an error to be handled by the suspended function */
  function error(error:Any):Void;
}
```

When compiled, suspending functions receive continuation as an argument which is then used to return the control and some value or an error to the caller. So, for example a very simple suspending (but not really) function would be transformed like this:

```haxe
suspend function getAnswer(arg:Bool):Int {
  if (arg)
    return 42;
  else
    throw "oh no";
}

// becomes...

function getAnswer(arg:Bool, continuation:Continuation<Int>):Void {
  if (arg)
    continuation.resume(42);
  else
    continuation.error("oh no");
}
```

This is quite similar to node.js `(error,result)` callback convention and is generally called [continuation-passing style](https://en.wikipedia.org/wiki/Continuation-passing_style).

### State machines

Coroutines that are suspended in the middle of their body, not just at the end (aka tail call) have to be transformed into state machine objects that maintain function state (local vars) between resumes.

Let's take a look at our (slightly modified) `greet` function:

```haxe
function speak(text:String):Void;
suspend function listen():String;

suspend function greet() {
  speak('What is your name'?);
  var name = listen(); // execution is suspended here
  speak('Hello, $name!');
}
```

Given that `listen` is a suspending function, and `speak` is a normal function, this function has one suspension point - the `listen()` call and two parts of execution (states):

 0. code before the suspension point
 1. code after the suspension point

We generate the code for it similar to the following:

```haxe
function greet(continuation:Continuation<Void>) {
  var sm = new StateMachine_for_greet(continuation);
  sm.resume(null); // start the execution
}

class StateMachine_for_greet implements Continuation<Any> {
  var continuation:Continuation<Void>;
  var state:Int;

  public function new(continuation) {
    this.continuation = continuation;
    this.state = 0;
  }

  public function resume(result:Any):Void {
    do {
      switch (state) {
        case 0:
          speak('What is your name'?);
          state = 1;
          listen(this);
          return;
        case 1:
          var name:String = result; // we're resumed by `listen` which is supposed to return a string for us
          speak('Hello, $name!');
          state = -1;
          continuation.resume(null);
          return;
        case _:
          throw "Invalid state";
      }
    } while (true); // this can be replaced by goto operators for targets that support them
  }

  public function error(error:Any):Void {
    continuation.error(error); // forward errors to the caller since we don't handle any here
  }
}
```

The generated `StateMachine_for_greet` class implements the `Continuation` interface and passing itself to the suspending `listen` call to resume its execution after `listen` returns the result. This way there's no need for additional allocations and there's only one object representing a coroutine.

The state machine object stores the original suspending function arguments (just the `continuation` in this case) as fields so they are persisted between `resume` calls. It also has an additional `state` field to save the current execution state so it knows where to continue when resumed next time.

If there were local variables that are shared between states, it would also have to store them in a field so their value is persisted between resumes.

Naturally, when created, the state machine is in the 0-th state, at the beginning of the function, before executing any of its code.

When `resume` is called for the first time right after the creation it proceeds executing the portion code of until the first suspension point, the `listen` call. Our first state consist of a `speak('What is your name'?)` call and a suspending `listen()` call. Before the suspending call it switches to the next state so it knows how to proceed after resuming.

When `listen` finishes and wants to return the value to the caller, it calls `resume` with that value on the `continuation` object it was given, which is actually our state machine.

The state machine is now in state `1` which is the second state, and it has the result of the suspending call given as an argument to `resume`, so it can proceed further. It executes the rest of the code after the suspension, which is the `speak` call, sets its `state` property to an invalid value, resumes the caller `continuation` and exits.

There's no code left to execute in our state machine now, so it can be safely thrown away and garbage-collected along with all its context.

### Implementation hints

As far as I understand the state machine building algorithm depends on a control flow graph, that we luckily already build after typing, so I assume the CFG builder has to be modified so it's aware of suspending calls and creates basic block for coroutine states with "suspend" edges. After the CFG is built, it's fed to a state machine builder that generates the state machine class with the switch and suspension calls and changes the original function.

Since coroutine class methods may need to access `super` methods, it might be a good idea to generate the actual `resume`/`error` state machine functions in the class as well (by using name mangling like `_hx_origMethodName_suspendResume` and make state machine object call them.

### Entering coroutines

Now that we covered how coroutines interact with each other by passing continuations, we need to figure out how coroutines are launched from the regular non-suspending world.

Let's take a look at these suspending functions:

```haxe
suspend function speak(phrase:String):Void;
suspend function listen():String;
```

First, we need a type to distinguish suspending functions from normal functions. The simpliest solution would be to have a compiler-supported abstract type like this:

```haxe
@:coreType abstract Suspend<T:Function> {}
```

Our `listen` function would then have the type `Suspend<Void->String>` and our `speak` would be correspondigly typed as `Suspend<String->Void>`.

Second, we need a way to actually start the execution of a suspending function. For that we have a `start` method for `Suspend<T>` types that is provided by compiler, similarly to how `bind` is provided for normal functions. That method would accept normal arguments defined in the suspending function signature as well as the `continuation` additional argument for handling the result/error. For example:

```haxe
// a regular function
function main() {
  speak.start("Hello!", new FireAndForgetContinuation());
  listen.start(new CallbackContinuation(answer -> trace('Answer is: $answer')));
}

// custom Continuation implementations depending how we want to handle coroutine results

class CallbackContinuation<T> implements Continuation<T> {
  var callback:T->Void;
  public function new(callback) { this.callback = callback; }
  public function resume(result:T):Void { callback(result); }
  public function error(error:Any):Void { throw error; }
}

class FireAndForgetContinuation<T> implements Continuation<T> {
  public function new() {}
  public function resume(result:T):Void {}
  public function error(error:Any):Void { throw error; }
}
```

Since suspending functions are compiled to normal functions with an additional `continuation` argument, `.start` calls would be straightforwardly translated into a direct call of a transformed suspending function:

```haxe
function main() {
  speak("Hello!", new FireAndForgetContinuation());
  listen(new CallbackContinuation(answer -> trace('Answer is: $answer')));
}
```

### Accessing continuation objects

When writing coroutines we don't normally have access to the `Continuation` objects that connect suspending function calls together, because the additional continuation argument is added later by the transformation is generally an implementation detail.

However, to integrate with third-party asynchronous code we need to be able to write suspending functions that can connect third-party API callbacks to our coroutine machinery. There are more cases when we'd want to control continuations directly, like generator coroutines that are called on some `next()` call. For that we need to access `resume` and `error` methods of the continuation object.

We provide a magic extern function, that is handled at compile-time:

```haxe
extern class CoroutineTools {
  static function suspendCoroutine<T>(fn:Continuation<T>->Void):T;
}
```

This function, when called from within another suspending function will suspend the caller and immediately call the given `fn` argument. For example, let's create an `await` suspending method for JavaScript promises:

```haxe
suspend function await<T>(p:js.Promise<T>):T {
  return suspendCoroutine(c -> p.then(c.resume, c.error));
}
```

As one can imagine, this function allows pausing coroutines for awaiting `Promise` completion, effectively allowing to work with any promise-powered API.

What `suspendCoroutine` actually does is simply exposing the implicit `continuation` object in a safe way. So, ideally (with everything inlined properly), the generated `await` code should look like this:

```haxe
function await<T>(p:js.Promise<T>, continuation:Continuation<T>):Void {
  p.then(continuation.resume, continuation.error);
}
```

### Integration

As shown in the previous section, "awaiting" JS promises in a coroutine is quite straightforward, but we can also quite easily construct a promise from a coroutine:

```haxe
suspend function doStuff():Int;

function doPromisedStuff():Promise<Int> {
  return new Promise(function(resolve, reject) {
    doStuff.start(new CallbackContinuation(resolve, reject));
  });
}

class CallbackContinuation<T> implements Continuation<T> {
  var resolve:T->Void;
  var reject:Any->Void;
  public function new(resolve, reject) {
    this.resolve = resolve;
    this.reject = reject;
  }
  public function resume(result:T) resolve(result);
  public function error(error:Any) reject(error);
}
```

Let's now look at some more examples of integration with third party asynchronous APIs.

#### thx.promise

Implementing `await` for `thx.promise` promises is the same as for `js.Promise`:

```haxe
suspend function await<T>(p:thx.Promise<T>):T {
  return suspendCoroutine(c -> p.either(c.resume, c.error));
}
```

#### tink_core

tink_core's `Promise` can be awaited similarly:

```haxe
suspend function await<T>(f:Promise<T>):T {
  return suspendCoroutine(c ->
    f.handle(function(outcome) switch outcome {
      case Success(data): c.resume(data);
      case Failure(failure): c.error(failure);
    })
  );
}
```

#### Other computation abstractions

It's similar with .NET `Task.ContinueWith`, Java 8 `CompletableFuture.whenComplete`, etc. You get the idea. :-)

#### hxnodejs (and similar continuation passing style APIs)

Node.js provides very simple explicit continuation-passing style API, for example:

```haxe
extern class Fs {
  static function readFile(filename:String, callback:Error->String->Void):Void;
}
```

to make this function usable in coroutines, we write (or generate) a simple wrapper:

```haxe
class CoroutineAwareFs {
  suspend inline static function readFile(filename:String):String {
    return suspendCoroutine(c ->
      Fs.readFile(filename, function(error, result) {
        if (error == null) c.resume(result)
        else c.error(error);
      })
    );
  }
}
```

Note the `inline` modifier in a suspending function. That should be possible, since suspending function transformation is fairly simple, especially in tail-call cases like the above when state machine doesn't need to be created, so calling this `readFile` function from another coroutine function or its state machine could be inlined to the direct `Fs.readFile` call. Let's look at the simple state machine generated (ideally) for the following function:

source:
```haxe
suspend function loadJson(path:String):Any {
  return haxe.Json.parse(CoroutineAwareFs.readFile(path));
}
```

generated:
```haxe
function loadJson(path:String, continuation:Continuation<Any>) {
  new StateMachine_for_loadJson(path, continuation).resume(null);
}

class StateMachine_for_loadJson implements Continuation<Any> {
  // ... constructor and fields skipped for brevity ...
  function resume(result:Any) {
    do {
      switch (state) {
        case 0:
          state = 1;
          // since state machine passes itself as the continuation, the `readFile` callback
          // calls the state machine directly, reducing the coroutine overhead to the minimum
          var _gthis = this;
          Fs.readFile(filename, function(error, result) {
            if (error == null) _gthis.resume(result)
            else _gthis.error(error);
          });
          return;
        case 1:
          state = -1;
          continuation.resume(haxe.Json.parse(result));
          return;
        case _:
          throw "Invalid state";
      }
    } while(true);
  }
}
```

#### awaiting continuation passing style functions

Alternatively, one might want to be explicit about suspending a coroutine when calling e.g. a node.js CPS function. So instead of writing/generating coroutine-aware versions of the API, we could write a generic `await` function that takes a partially applied cps-function, calls it and suspends the coroutine:

```haxe
suspend inline function await<T>(fn:(Error->T->Void)->Void):T {
  return suspendCoroutine(c ->
    fn(function(error, result) {
      if (error == null) c.resume(result)
      else c.error(error);
    })
  );
}
```

The `loadJson` example from the previous section using our `await` function would looke like this:

```haxe
suspend function loadJson(path:String):Any {
  return haxe.Json.parse(await(Fs.readFile.bind(path)));
}
```

The generated code, with everything inlined properly should be the same as before, no additional closures.

If the syntax is not clear enough, one could make `await` a very simple macro function that would allow for a more minimalistic syntax like this:

```haxe
await(Fs.readFile(path)); // or await(Fs.readFile(path, _)) for more explicitness
```

### Local suspending functions

Of course, not only methods can be coroutines, local functions both named and anonymous should support being coroutines. The proposed syntax using the `suspend` keyword would be:

```haxe
suspend function localCoroutine(arg:Int) {
  // ...
}

var localCoroutine = suspend () -> {
  // ...
};
```

For anonymous functions, when the expected type is known to be `Suspend<T>`, having `suspend` keyword is not required and can be omitted. Function will be inferred to be suspendable. This allows for handy coroutine "builder" functions, e.g.:

```haxe
function promise(fn:Suspend<Void->T>):Promise<T> {
  return new Promise(function(resolve, reject) {
    fn.start(new CallbackContinuation(resolve, reject));
  });
}
```

Which can be later used to transform any suspendable computation in a Promise, e.g.:

```haxe
suspend function sleep(ms:Int):Void; // suspend coroutine for the given amount of milliseconds somehow

suspend function example() {
  var p1 = promise(() -> {
    trace("p1 started");
    sleep(1000);
    trace("p1 exits");
    return 1;
  });

  var p2 = promise(() -> {
    trace("p2 started");
    sleep(1000);
    trace("p2 exits");
    return 2;
  });

  trace("waiting for p1 and p2 to finish (should take 1 second)");
  var result = await(p1) + await(p2);
  trace('result = $sum!');
}
```

The execution of this `example` coroutine should take one second and print:

```
p1 started
p2 started
waiting for p1 and p2 to finish (should take 1 second)

... 1 second later ...

p1 exits
p2 exits
result = 3
```


### Optimization

One of simple and useful optimizations would be to allow returning values from `suspend` functions synchonously. Imagine a function like this:

```haxe
suspend function loadPage(path:String):String {
  if (cache.exists(path))
    return cache.get(path);
  else
    return doLoadPageAsync(path);
}
```

In case the loaded page is in cache, we can simply return the result synchronously and don't want to grow our stack size by calling back the caller through continuation. We can support that by directly returning the value like it's a normal function, but if we want to do an actual suspension, we need some marker value, different from any other value:

```haxe
typedef SuspendResult<T> = haxe.extern.EitherType<T,SuspendMarker>;
enum SuspendMarker { SuspendMarker; } // could be any static object

// generated
function loadPage(path:String, continuation:Continuation<String>):SuspendResult<String> {
  if (cache.exists(path))
    return cache.get(path);
  else
    return doLoadPageAsync(path, continuation); // another optimization: we don't need state machine
                                                // for the tail suspending call
}

function doLoadPageAsync(path:String, continuation:Continuation<String>):SuspendResult<String> {
  var sm = new StateMachine_for_doLoadPageAsync(path, continuation);
  sm.resume(null); // start the execution
  return SuspendMarker; // return that we want to suspend the caller
}
```

a state machine that then calls this `loadPage` function would look something like this:

```haxe
public function resume(result:Any):Void {
  do {
    switch (state) {
      case 0:
        state = 1;
        var tmp = loadPage("somepath", this);
        if (tmp == SuspendMarker) return // if function suspended - exit and wait for resuming
        else result = tmp; // else it returned the actual result we can use, proceed to state 1

      case 1:
        var page:String = result;
        print(page);
        state = -1;
        return;

      case _:
        throw "Invalid state";
    }
  } while (true); // this can be replaced by goto operators for targets that support them
}
```

### More usage examples

We've already shown some examples of creating and awaiting promises using coroutines (see previous sections), let's now
take a look at some use-cases for coroutines that are not directly related to awaiting asynchronous computations.

#### Generators

`yield` would be a simple suspending function and we can use anonymous suspending function for the generator body like this:

```haxe
typedef Yield<T> = Suspend<T->Void>;

function buildGenerator<T>(coro:Suspend<Yield<T>->Void>):Iterator<T>;

var gen = buildGenerator(yield -> {
  var i = 0;
  while (true) {
    yield(i);
    i++;
  }
});

for (v in gen) {
  trace(v);
}
```

> **TODO**: this needs a way to create a coroutine without actually starting it, because the coroutine should be resumed when `next` is called, not right away

#### Mutexes

One could combine coroutines and multi-threading by creating a mutex whose `lock` function suspends the execution of a coroutine, so other coroutines could work without blocking the whole thread while waiting for the mutex.

```haxe
class Mutex {
  suspend function lock():Void;
  function unlock():Void;
}

var mutex:Mutex;

suspend function doSomething() {
  mutex.lock(); // suspend until mutex is lockable
  // ... process ...
  mutex.unlock();
}
```

> TODO: port some nice examples, like https://tour.golang.org/concurrency/9

#### Go-style concurrency

Coroutines can be used to implement concurrency with channels similar to Go:

```haxe
interface SendChannel<T> {
  suspend function send(value:T):Void;
}

interface ReceiveChannel<T> {
  suspend function receive():T;
}

class Channel<T> implements SendChannel<T> implements ReceiveChannel<T> {
  // ...implementation here
}

/** Starts a coroutine in a multi-threaded pool */
function go<T:Function>(coro:Suspend<T>);

// ---

suspend function naturals(n:Int, c:SendChannel<Int>) {
  for (i in 0...n)
    c.send(i);
}

function main() {
  var c = new Channel();

  go(() -> naturals(10, c)); // dispatch coro to some thread

  trace(c.receive()); // receive values from the channel
  trace(c.receive());
  trace(c.receive());
}
```

> TODO: port https://tour.golang.org/concurrency/4
