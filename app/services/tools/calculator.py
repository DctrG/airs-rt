import ast
import operator as op


_operators = {
    ast.Add: op.add,
    ast.Sub: op.sub,
    ast.Mult: op.mul,
    ast.Div: op.truediv,
    ast.Pow: op.pow,
    ast.Mod: op.mod,
}


def _eval(node):
    if isinstance(node, ast.Num):
        return node.n
    if isinstance(node, ast.BinOp) and type(node.op) in _operators:
        return _operators[type(node.op)](_eval(node.left), _eval(node.right))
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
        val = _eval(node.operand)
        return +val if isinstance(node.op, ast.UAdd) else -val
    raise ValueError("Unsupported expression")


async def calculator(params: dict):
    expression = (params or {}).get("expression")
    if not expression or not isinstance(expression, str):
        return {"error": "Missing expression"}
    try:
        node = ast.parse(expression, mode="eval")
        value = _eval(node.body)
        if value is None or value != value:
            return {"error": "Expression did not evaluate to a finite number"}
        return {"expression": expression, "value": value}
    except Exception as e:
        return {"error": str(e)}


