import Macro.transform;
import js.Promise;

typedef Continuation<T> = T->Void;

class Main {
	static var nextNumber = 0;
	static function getNumber(cb:Int->Void) cb(++nextNumber);
	static function getNumberP() return new Promise((resolve,_) -> getNumber(resolve));

	// known (hard-coded) suspending functions
	inline static function await<T>(f:(T->Void)->Void, cont:Continuation<T>):Void f(cont);
	inline static function awaitP<T>(p:Promise<T>, cont:Continuation<T>):Void p.then(cont);
	static function test(n:Int, cont:Continuation<String>):Void cont('hi $n times');

	static function main() {
		var coro = transform(function(n:Int):Int {
			trace("hi");
			var v = 0;
			while (v++ < 10) {
				trace(test(await(getNumber)));
			}
			var v = await(getNumber) + awaitP(getNumberP());
			return n + v + await(getNumber);
		});
		coro(10, value -> trace('Result: $value'));
	}
}
