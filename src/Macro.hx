#if macro
import haxe.ds.GenericStack;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
using haxe.macro.Tools;

enum Edge {
	Final;
	Suspend(fn:Expr, args:Array<Expr>, bbNext:BasicBlock);
	Next(bbNext:BasicBlock);
	Loop(bbHead:BasicBlock, bbBody:BasicBlock, bbNext:BasicBlock);
	LoopHead(bbBody:BasicBlock, bbNext:BasicBlock);
	LoopBack(bbHead:BasicBlock);
	LoopContinue(bbHead:BasicBlock);
	LoopBreak(bbNext:BasicBlock);
	IfThen(bbThen:BasicBlock, bbNext:BasicBlock);
	IfThenElse(bbThen:BasicBlock, bbElse:BasicBlock, bbNext:BasicBlock);
	Return;
}

class BasicBlock {
	public var id(default,null):Int;
	public var elements(default,null):Array<Expr>;
	public var edge(default,null):Edge;
	public var vars(default,null):Array<Var>;

	public function new(id) {
		this.id = id;
		elements = [];
		vars = [];
		edge = Final;
	}

	public function addElement(e) elements.push(e);
	public function setEdge(e) edge = e;

	public function declareVar(name, type) {
		vars.push({name: name, type: type, expr: null});
		// elements.push(macro var $name:$type);
	}

	public function assignVar(name, expr) {
		elements.push(macro $i{name} = $expr);
	}
}

class UnreachableBlock extends BasicBlock {
	override function setEdge(e) {}
}

class LoopContext {
	public var bbHead:BasicBlock;
	public var breaks:Array<BasicBlock>;

	public function new(bbHead) {
		this.bbHead = bbHead;
		breaks = [];
	}

	public function addBreak(bb) {
		breaks.push(bb);
	}

	public function close(bbNext:BasicBlock) {
		for (bb in breaks)
			bb.setEdge(LoopBreak(bbNext));
	}
}

class FlowGraph {
	static var fakeValue = macro null;

	public var hasSuspend(default,null) = false;
	var nextBlockId = 0;
	var bbUnreachable = new UnreachableBlock(-1);
	var loopStack = new GenericStack<LoopContext>();

	function new() {}

	function block(bb:BasicBlock, e:Expr):BasicBlock {
		switch e.expr {
			case EBlock(exprs):
				for (e in exprs) {
					bb = blockElement(bb, e);
				}
			case _:
				bb = blockElement(bb, e);
		}
		return bb;
	}

	function blockElement(bb:BasicBlock, e:Expr):BasicBlock {
		return switch e.expr {
			case EDisplayNew(_):
				bb;

			case EBlock(exprs):
				for (e in exprs)
					bb = blockElement(bb, e);
				bb;

			case EConst(_) | EField(_, _) |  ECall(_,_) | EBinop(_, _, _) | EUnop(_, _, _) | EParenthesis(_) | EArray(_, _) | EArrayDecl(_) | ECast(_, _) | ECheckType(_, _) | EObjectDecl(_) | ENew(_, _):
				var r = value(bb, e);
				r.bb.addElement(r.e);
				r.bb;

			case EMeta(_, e2):
				blockElement(bb, e2); // TODO: just lose the meta, meh

			case EVars(vl):
				for (v in vl) {
					bb.declareVar(v.name, v.type);
					if (v.expr != null) {
						var r = value(bb, v.expr);
						bb = r.bb;
						bb.assignVar(v.name, r.e);
					}
				}
				bb;

			case EReturn(eRet):
				if (eRet == null) {
					bb.setEdge(Return);
					bb.addElement(macro null);
				} else {
					var r = value(bb, eRet);
					r.bb.setEdge(Return);
					r.bb.addElement(r.e);
				}
				bbUnreachable;

			case EWhile(econd, ebody, true):
				var bbHead = createBlock();

				var r = value(bbHead, econd);
				var bbHeadNext = r.bb;
				bbHeadNext.addElement(r.e);

				var bbBody = createBlock();
				var loopContext = new LoopContext(bbHead);
				loopStack.add(loopContext);
				var bbBodyNext = block(bbBody, ebody);
				loopStack.pop();
				bbBodyNext.setEdge(LoopBack(bbHead));

				var bbNext = createBlock();
				loopContext.close(bbNext);
				bbHeadNext.setEdge(LoopHead(bbBody, bbNext));

				bb.setEdge(Loop(bbHead, bbBody, bbNext));
				bbNext;

			case EContinue:
				var loopContext = loopStack.first();
				if (loopContext == null)
					throw new Error("continue outside of loop", e.pos);
				bb.setEdge(LoopContinue(loopContext.bbHead));
				bbUnreachable;

			case EBreak:
				var loopContext = loopStack.first();
				if (loopContext == null)
					throw new Error("break outside of loop", e.pos);
				loopContext.addBreak(bb);
				bbUnreachable;

			case EIf(econd, ethen, eelse) | ETernary(econd, ethen, eelse):
				var r = value(bb, econd);
				bb = r.bb;
				bb.addElement(r.e);

				var bbThen = createBlock();
				var bbThenNext = block(bbThen, ethen);

				var bbNext;
				if (eelse != null) {
					var bbElse = createBlock();
					var bbElseNext = block(bbElse, eelse);
					bbNext = createBlock();
					bbThenNext.setEdge(Next(bbNext));
					bbElseNext.setEdge(Next(bbNext));
					bb.setEdge(IfThenElse(bbThen, bbElse, bbNext));
				} else {
					bbNext = createBlock();
					bbThenNext.setEdge(Next(bbNext));
					bb.setEdge(IfThen(bbThen, bbNext));
				}
				bbNext;

			case EDisplay(_,_) | EFor(_,_) | EFunction(_,_) | ESwitch(_,_,_) | EThrow(_) | ETry(_,_) | EUntyped(_) | EWhile(_,_,_):
				throw new Error('${e.expr.getName()} not implemented', e.pos);
		}
	}

	var tmpVarId = 0;

	function value(bb:BasicBlock, e:Expr):{bb:BasicBlock, e:Expr} {
		return switch e.expr {
			case EConst(_) | EBlock([]) | EDisplayNew(_):
				{bb: bb, e: e};

			case EBlock(el):
				var last = el[el.length - 1];
				for (i in 0...el.length - 1)
					bb = blockElement(bb, el[i]);
				value(bb, last);

			case EField(eobj, f):
				var r = value(bb, eobj);
				{bb: r.bb, e: {pos: e.pos, expr: EField(r.e, f)}};

			case EParenthesis(e1):
				var r = value(bb, e1);
				{bb: r.bb, e: {pos: e.pos, expr: EParenthesis(r.e)}};

			case EReturn(_) | EBreak | EContinue:
				bb = blockElement(bb, e);
				{bb: bb, e: fakeValue};

			case EBinop(op, ea, eb):
				var r = value(bb, ea);
				bb = r.bb;
				ea = r.e;

				r = value(bb, eb);
				bb = r.bb;
				eb = r.e;

				{bb: bb, e: {expr: EBinop(op, ea, eb), pos: e.pos}};

			case EUnop(op, postfix, e):
				var r = value(bb, e);
				{bb: r.bb, e: {expr: EUnop(op, postfix, r.e), pos: e.pos}};

			case ECall(eobj, args):
				call(bb, eobj, args, e.pos);

			case EArray(eobj, eindex):
				var r = value(bb, eobj);
				eobj = r.e;
				bb = r.bb;

				r = value(bb, eindex);
				eindex = r.e;
				bb = r.bb;

				{bb: bb, e: {expr: EArray(eobj, eindex), pos: e.pos}};

			case EArrayDecl(el):
				el = [
					for (e in el) {
						var r = value(bb, e);
						bb = r.bb;
						e;
					}
				];
				{bb: bb, e: {expr: EArrayDecl(el), pos: e.pos}};

			case ENew(tp, args):
				args = [
					for (e in args) {
						var r = value(bb, e);
						bb = r.bb;
						e;
					}
				];
				{bb: bb, e: {expr: ENew(tp, args), pos: e.pos}};

			case EObjectDecl(fields):
				fields = [
					for (f in fields) {
						var r = value(bb, f.expr);
						bb = r.bb;
						{field: f.field, expr: r.e};
					}
				];
				{bb: bb, e: {expr: EObjectDecl(fields), pos: e.pos}};

			case ECast(eobj, t):
				var r = value(bb, eobj);
				{bb: r.bb, e: {expr: ECast(r.e, t), pos: e.pos}};

			case ECheckType(eobj, t):
				var r = value(bb, eobj);
				{bb: r.bb, e: {expr: ECheckType(r.e, t), pos: e.pos}};

			case EDisplay(eobj, c):
				var r = value(bb, eobj);
				{bb: r.bb, e: {expr: EDisplay(r.e, c), pos: e.pos}};

			case EMeta(m, eobj):
				var r = value(bb, eobj);
				{bb: r.bb, e: {expr: EMeta(m, r.e), pos: e.pos}};

			case EVars(_):
				throw new Error("Var declaration in value places are not allowed", e.pos);

			case EWhile(_, _ ,_) | EFor(_, _):
				throw new Error("Loop in value places are not allowed", e.pos);

			case EIf(econd, ethen, eelse) | ETernary(econd, ethen, eelse):
				if (eelse == null)
					throw new Error("If in a value place must have an else branch", e.pos);

				var r = value(bb, econd);
				bb = r.bb;
				bb.addElement(r.e);

				var tmpVarName = "tmp" + (tmpVarId++);
				bb.declareVar(tmpVarName, null);

				var bbThen = createBlock();
				var bbThenNext = {
					var r = value(bbThen, ethen);
					r.bb.assignVar(tmpVarName, r.e);
					r.bb;
				}

				var bbElse = createBlock();
				var bbElseNext = {
					var r = value(bbElse, eelse);
					r.bb.assignVar(tmpVarName, r.e);
					r.bb;
				}

				var bbNext = createBlock();
				bbThenNext.setEdge(Next(bbNext));
				bbElseNext.setEdge(Next(bbNext));
				bb.setEdge(IfThenElse(bbThen, bbElse, bbNext));

				{bb: bbNext, e: macro $i{tmpVarName}};

			case EFunction(_,_) | ESwitch(_,_,_) | EThrow(_) | ETry(_,_) | EUntyped(_):
				throw new Error('${e.expr.getName()} not implemented', e.pos);
		}
	}

	function call(bb:BasicBlock, eobj:Expr, args:Array<Expr>, pos:Position):{bb:BasicBlock, e:Expr} {
		var r = value(bb, eobj);
		bb = r.bb;
		eobj = r.e;

		args = [for (e in args) {
			var r = value(bb, e);
			bb = r.bb;
			r.e;
		}];

		return switch eobj.expr {
			case EConst(CIdent("await" | "awaitPromise" | "test" | "yield")): // any suspending function, actually
				hasSuspend = true;
				var tmpVarName = "tmp" + (tmpVarId++);
				bb.declareVar(tmpVarName, null);
				var bbNext = createBlock();
				bbNext.addElement(macro $i{tmpVarName} = __result);
				bb.setEdge(Suspend(eobj, args, bbNext));
				{bb: bbNext, e: macro $i{tmpVarName}};
			case _:
				{bb: bb, e: {expr: ECall(eobj, args), pos: pos}};
		}
	}

	function createBlock() return new BasicBlock(nextBlockId++);

	public static function build(fun:Function):{root:BasicBlock, hasSuspend:Bool} {
		var graph = new FlowGraph();
		var bbRoot = graph.createBlock();
		graph.block(bbRoot, fun.expr);
		return {root: bbRoot, hasSuspend: graph.hasSuspend};
	}
}
#end

class Macro {
	public static macro function transform(expr) {
		return switch expr.expr {
			case EFunction(name, fun):
				{expr: EFunction(name, doTransform(fun, expr.pos)), pos: expr.pos};
			case _:
				throw new Error("Function expected", expr.pos);
		}
	}

	#if macro
	static function doTransform(fun:Function, pos:Position):Function {
		var returnCT = if (fun.ret != null) fun.ret else throw new Error("Return type hint expected", pos);
		if (returnCT.toString() == "Void") returnCT = macro : Dynamic;

		var coroArgs = fun.args.copy();
		coroArgs.push({name: "__continuation", type: macro : Continuation<$returnCT>});

		var cfg = FlowGraph.build(fun);

		var coroExpr = if (cfg.hasSuspend) {
			buildStateMachine(cfg.root, fun.expr.pos);
		} else {
			buildStateMachine(cfg.root, fun.expr.pos);
			// buildSimpleCPS(cfg.root, fun.expr.pos);
		}

		trace(coroExpr.toString());

		return {
			args: coroArgs,
			ret: macro : Continuation<Any>,
			expr: coroExpr
		};
	}

	static function buildStateMachine(bbRoot:BasicBlock, pos:Position):Expr {
		var cases = new Array<Case>();
		var varDecls = [];

		function loop(bb:BasicBlock) {
			var exprs = [];
			for (v in bb.vars)
				varDecls.push(v);

			switch bb.edge {
				case Return:
					var last = bb.elements[bb.elements.length - 1];
					for (i in 0...bb.elements.length - 1)
						exprs.push(bb.elements[i]);

					exprs.push(macro {
						__state = -1;
						__continuation($last);
						return;
					});

				case Final:
					for (e in bb.elements) exprs.push(e);
					exprs.push(macro {
						__state = -1;
						__continuation(null);
						return;
					});

				case Suspend(ef, args, bbNext):
					for (e in bb.elements) exprs.push(e);

					args.push(macro __stateMachine);

					exprs.push(macro {
						__state = $v{bbNext.id};
						$ef($a{args});
						return;
					});
					loop(bbNext);

				case Next(bbNext) | Loop(bbNext, _, _):
					for (e in bb.elements) exprs.push(e);
					loop(bbNext);
					exprs.push(macro __state = $v{bbNext.id});

				case IfThen(bbThen, bbNext):
					var econd = bb.elements[bb.elements.length - 1];
					for (i in 0...bb.elements.length - 1)
						exprs.push(bb.elements[i]);

					loop(bbThen);
					loop(bbNext);

					exprs.push(macro {
						if ($econd) {
							__state = $v{bbThen.id};
						} else {
							__state = $v{bbNext.id};
						}
					});

				case IfThenElse(bbThen, bbElse, _):
					var econd = bb.elements[bb.elements.length - 1];
					for (i in 0...bb.elements.length - 1)
						exprs.push(bb.elements[i]);

					loop(bbThen);
					loop(bbElse);

					exprs.push(macro {
						if ($econd) {
							__state = $v{bbThen.id};
						} else {
							__state = $v{bbElse.id};
						}
					});

				case LoopHead(bbBody, bbNext):
					var econd = bb.elements[bb.elements.length - 1];
					for (i in 0...bb.elements.length - 1)
						exprs.push(bb.elements[i]);

					loop(bbBody);
					loop(bbNext);

					exprs.push(macro {
						if ($econd) {
							__state = $v{bbBody.id};
						} else {
							__state = $v{bbNext.id};
						}
					});

				case LoopBack(bbGoto) | LoopContinue(bbGoto) | LoopBreak(bbGoto):
					for (e in bb.elements) exprs.push(e);
					exprs.push(macro {
						__state = $v{bbGoto.id};
					});
			}

			cases.unshift({
				values: [macro $v{bb.id}],
				expr: macro $b{exprs}
			});
		}
		loop(bbRoot);

		var eswitch = {
			pos: pos,
			expr: ESwitch(macro __state, cases, macro throw "Invalid state")
		};

		return macro {
			var __state = 0;
			${{pos: pos, expr: EVars(varDecls)}};
			function __stateMachine(__result:Dynamic) {
				do $eswitch while (true);
			}
			// __stateMachine(null);
			return __stateMachine;
		};
	}

	// static function buildSimpleCPS(bbRoot:BasicBlock, pos:Position):Expr {
	// 	function loop(bb:BasicBlock, exprs:Array<Expr>) {
	// 		switch bb.edge {
	// 			case Suspend(_):
	// 				throw "Suspend in a non-suspending coroutine?";

	// 			case Return:
	// 				var last = bb.elements[bb.elements.length - 1];
	// 				for (i in 0...bb.elements.length - 1)
	// 					exprs.push(bb.elements[i]);
	// 				exprs.push(macro __continuation($last));
	// 				exprs.push(macro return);

	// 			case Next(bbNext):
	// 				for (e in bb.elements) exprs.push(e);
	// 				loop(bbNext, exprs);

	// 			case Loop(bbHead, bbBody, bbNext):
	// 				for (e in bb.elements) exprs.push(e);

	// 				var headExprs = [];
	// 				loop(bbHead, headExprs);
	// 				var condExpr = headExprs.pop();
	// 				var bodyExprs = [];
	// 				loop(bbBody, bodyExprs);
	// 				var loopExpr = macro {
	// 					$b{headExprs};
	// 					if (!$condExpr) break;
	// 					$b{bodyExprs};
	// 				};
	// 				exprs.push(macro do $loopExpr while (true));
	// 				loop(bbNext, exprs);

	// 			case LoopHead(_, _) | LoopBack(_):
	// 				for (e in bb.elements) exprs.push(e);

	// 			case LoopContinue(_):
	// 				for (e in bb.elements) exprs.push(e);
	// 				exprs.push(macro continue);

	// 			case LoopBreak(_):
	// 				for (e in bb.elements) exprs.push(e);
	// 				exprs.push(macro break);

	// 			case IfThen(_, _) | IfThenElse(_, _, _):
	// 				throw "TODO";
	// 		}
	// 	}

	// 	var exprs = [];
	// 	loop(bbRoot, exprs);
	// 	return macro $b{exprs};
	// }
	#end
}
