import Macro.transform;
import js.Promise;

typedef Continuation<T> = T->Void;

class Main {
	// some async API
	static var nextNumber = 0;
	static function getNumber(cb:Int->Void) cb(++nextNumber);
	static function getNumberPromise() return new Promise((resolve,_) -> getNumber(resolve));

	// known (hard-coded for now) suspending functions
	inline static function await<T>(f:(T->Void)->Void, cont:Continuation<T>):Void
		f(cont);

	inline static function awaitPromise<T>(p:Promise<T>, cont:Continuation<T>):Void
		p.then(cont);

	static function test(n:Int, cont:Continuation<String>):Void
		cont('hi $n times');

	static function main() {
		// sample coroutine
		var coro = transform(function(n:Int):Int {

			trace("hi");

			while (await(getNumber) < 10) {
				trace('wait for it...');

				var promise = getNumberPromise();
				trace(awaitPromise(promise));
			}

			trace("bye");
			return 15;

		});

		coro(10, value -> trace('Result: $value'));
	}
}
