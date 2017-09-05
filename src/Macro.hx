#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
using haxe.macro.Tools;

enum Edge {
	None;
	Suspend(fn:Expr, args:Array<Expr>, bbNext:BasicBlock);
	Next(bbNext:BasicBlock);
	Loop(bbHead:BasicBlock, bbBody:BasicBlock, bbNext:BasicBlock);
	LoopHead(bbBody:BasicBlock, bbNext:BasicBlock);
	LoopBack(bbHead:BasicBlock);
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
		edge = None;
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

class FlowGraph {
	static var fakeValue = macro null;

	public var hasSuspend(default,null) = false;
	var nextBlockId = 0;
	var bbUnreachable = new UnreachableBlock(-1);

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
			case EConst(_) | EField(_, _) |  ECall(_,_) | EBinop(_, _, _) | EUnop(_, _, _) | EParenthesis(_):
				var r = value(bb, e);
				r.bb.addElement(r.e);
				r.bb;

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

			case EWhile(econd,ebody,true):
				var bbHead = createBlock();

				var r = value(bbHead, econd);
				var bbHeadNext = r.bb;
				bbHeadNext.addElement(r.e);

				var bbBody = createBlock();
				var bbBodyNext = block(bbBody, ebody);
				bbBodyNext.setEdge(LoopBack(bbHead));

				var bbNext = createBlock();
				bbHeadNext.setEdge(LoopHead(bbBody, bbNext));

				bb.setEdge(Loop(bbHead, bbBody, bbNext));
				bbNext;

			case EArray(_,_) | EArrayDecl(_) | EBlock(_) | EBreak | ECast(_,_) | ECheckType(_,_) | EContinue | EDisplay(_,_) | EDisplayNew(_) | EFor(_,_) | EFunction(_,_) | EIf(_,_,_) | EMeta(_,_) | ENew(_,_) | EObjectDecl(_) | ESwitch(_,_,_) | ETernary(_,_,_) | EThrow(_) | ETry(_,_) | EUntyped(_) | EWhile(_,_,_):
				throw new Error('${e.expr.getName()} not implemented', e.pos);
		}
	}

	var tmpVarId = 0;

	function value(bb:BasicBlock, e:Expr):{bb:BasicBlock, e:Expr} {
		return switch e.expr {
			case EConst(_) | EBlock([]):
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

			case EReturn(_):
				bb = blockElement(bb, e);
				{bb: bb, e: fakeValue};

			case EBinop(op = OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte | OpAdd | OpSub, ea, eb):
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

			case EArray(_,_) | EArrayDecl(_) | EBinop(_,_,_) | EBreak | ECast(_,_) | ECheckType(_,_) | EContinue | EDisplay(_,_) | EDisplayNew(_) | EFor(_,_) | EFunction(_,_) | EIf(_,_,_) | EMeta(_,_) | ENew(_,_) | EObjectDecl(_) | ESwitch(_,_,_) | ETernary(_,_,_) | EThrow(_) | ETry(_,_) | EUntyped(_) | EVars(_) | EWhile(_,_,_):
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
			case EConst(CIdent("await" | "awaitP" | "test")): // any suspending function, actually
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
		var fun, name;
		switch expr.expr {
			case EFunction(n, f):
				name = n;
				fun = f;
			case _:
				throw new Error("Function expected", expr.pos);
		}

		var returnCT = if (fun.ret != null) fun.ret else throw new Error("Return type hint expected", expr.pos);
		if (returnCT.toString() == "Void") returnCT = macro : Dynamic;

		var coroArgs = fun.args.copy();
		coroArgs.push({name: "__continuation", type: macro : Continuation<$returnCT>});

		var cfg = FlowGraph.build(fun);

		var coroExpr = if (cfg.hasSuspend) {
			buildStateMachine(cfg.root, fun.expr.pos);
		} else {
			buildSimpleCPS(cfg.root, fun.expr.pos);
		}

		trace(coroExpr.toString());

		var expr = {
			pos: expr.pos,
			expr: EFunction(name, {
				args: coroArgs,
				ret: macro : Void,
				expr: coroExpr
			})
		};

		return expr;
	}

	#if macro
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

				case LoopHead(bbBody, bbNext):
					var econd = bb.elements[bb.elements.length - 1];

					loop(bbBody);
					loop(bbNext);

					exprs.push(macro {
						if ($econd) {
							__state = $v{bbBody.id};
						} else {
							__state = $v{bbNext.id};
						}
					});

				case LoopBack(bbHead):
					for (e in bb.elements) exprs.push(e);
					exprs.push(macro {
						__state = $v{bbHead.id};
					});

				case None:
					throw "Unitialized block";
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
			__stateMachine(null);
		};
	}

	static function buildSimpleCPS(bbRoot:BasicBlock, pos:Position):Expr {
		function loop(bb:BasicBlock, exprs:Array<Expr>) {
			switch bb.edge {
				case Suspend(_):
					throw "Suspend in a non-suspending coroutine?";

				case Return:
					var last = bb.elements[bb.elements.length - 1];
					for (i in 0...bb.elements.length - 1)
						exprs.push(bb.elements[i]);
					exprs.push(macro __continuation($last));
					exprs.push(macro return);

				case Next(bbNext):
					for (e in bb.elements) exprs.push(e);
					loop(bbNext, exprs);

				case Loop(bbHead, bbBody, bbNext):
					for (e in bb.elements) exprs.push(e);

					var headExprs = [];
					loop(bbHead, headExprs);
					var condExpr = headExprs.pop();
					var bodyExprs = [];
					loop(bbBody, bodyExprs);
					var loopExpr = macro {
						$b{headExprs};
						if (!$condExpr) break;
						$b{bodyExprs};
					};
					exprs.push(macro do $loopExpr while (true));
					loop(bbNext, exprs);

				case LoopHead(_, _) | LoopBack(_):
					for (e in bb.elements) exprs.push(e);

				case None:
					throw "Unitialized block";
			}
		}

		var exprs = [];
		loop(bbRoot, exprs);
		return macro $b{exprs};
	}
	#end
}
