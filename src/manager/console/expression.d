module manager.console.expression;

import manager.console.command;

import urt.string;

struct Token
{
pure nothrow @nogc:

	enum Type : byte
	{
		Error = -1,
		None,
		Token,
		Identifier,
		Number,
		String,
		Command,
		Expression,
		Scope
	}

	this(Type type, const(char)[] token)
	{
		assert(token.length < 2^^24);
		this.type_len = cast(uint)((type << 24) | token.length);
		this.ptr = token.ptr;
	}
	this(const(char)[] token)
	{
		assert(token.length < 2^^24);

		Type type = determineTokenType(token);
		if (type == Type.None)
			token = null;
		this.type_len = cast(uint)((type << 24) | token.length);
		this.ptr = token.ptr;
	}

	Type type() const => cast(Type)(type_len >> 24);
	const(char)[] token() const => ptr[0 .. type_len & 0xFFFFFF];

private:
	const(char)* ptr = null;
	uint type_len = 0;

	struct Val { Type _type; const(char)[] _token; const(char)* ptr; uint type_len; }
	auto __debugOverview() const => Val(type, token, ptr, type_len);
	auto __debugExpanded() const => Val(type, token, ptr, type_len);
}

struct KVP
{
	Token k;
	Token v;
}

struct Expression
{
	Token* root;
}

Token takeToken(ref const(char)[] cmdLine)
{
	// take the next token, delimited by space, and also some special characters

	cmdLine = cmdLine.trimCmdLine;
	if (cmdLine.length == 0)
		return Token();

	const(char)* cmdStart = cmdLine.ptr;

	Token pair = cmdLine.takePair;
	if (pair.type == Token.Type.Error)
		return pair;
	if (pair.type != Token.Type.None)
	{
		if (cmdLine.length > 0 && !cmdLine[0].isWhitespace && cmdLine[0] != '=')
			return Token(Token.Type.Error, "Invalid token; expected separator");
		return pair;
	}

	size_t end = 0;
	for (; end < cmdLine.length && !cmdLine[end].isWhitespace && cmdLine[end] != '='; ++end)
	{
		// handle escape characters
		if (cmdLine[end] == '\\' && end < cmdLine.length)
		{
			end += 2;
			continue;
		}
		foreach (c; nonIdentifierChars)
			if (cmdLine[end] == c)
				return Token(Token.Type.Error, "Invalid token; expected separator");
	}
	cmdLine = cmdLine[end .. $];

	return Token(cmdStart[0 .. end].determineTokenType(), cmdStart[0 .. end]);
}

unittest
{
	static Token takeTokenTest(string s)
	{
		const(char)[] t = s;
		return t.takeToken;
	}
	assert(takeTokenTest("hello").token.length == 5);
	assert(takeTokenTest("hello world").token.length == 5);
	assert(takeTokenTest("hello=").token.length == 5);
	assert(takeTokenTest("hello=world").token.length == 5);

	assert(takeTokenTest("\"...\"").token.length == 5);
	assert(takeTokenTest("'...'").token.length == 5);
	assert(takeTokenTest("`...` ").token.length == 5);
	assert(takeTokenTest("(...) yay").token.length == 5);
	assert(takeTokenTest("[...]=").token.length == 5);
	assert(takeTokenTest("{...}=wow").token.length == 5);
	assert(takeTokenTest("\"...").type == Token.Type.Error);
	assert(takeTokenTest("(...").type == Token.Type.Error);
	assert(takeTokenTest("abc{...}").type == Token.Type.Error);
	assert(takeTokenTest("{...}abc").type == Token.Type.Error);
}

KVP takeKVP(ref const(char)[] cmdLine)
{
	KVP r;
	r.k = cmdLine.takeToken;
	if (r.k.type == Token.Type.Error)
		return r;
	if (cmdLine.length > 0 && cmdLine[0] == '=')
	{
		cmdLine = cmdLine[1 .. $];
		r.v = cmdLine.takeToken;
		if (r.v.type == Token.Type.Error)
			return KVP(r.v, Token());
		if (cmdLine.length > 0)
		{
			if (cmdLine[0] == '=')
				return KVP(Token(Token.Type.Error, "Only one '=' allowed in expression"), Token());
			else if (!cmdLine[0].isWhitespace)
				return KVP(Token(Token.Type.Error, "Invalid token; expected separator"), Token());
		}
	}
	return r;
}

unittest
{
	static KVP takeKVPTest(string s)
	{
		const(char)[] t = s;
		return t.takeKVP;
	}
//	assert(takeKVPTest("hello").token.length == 5);
//	assert(takeKVPTest("hello world").token.length == 5);
//	assert(takeKVPTest("hello=").token.length == 6);
//	assert(takeKVPTest("hello=world").token.length == 11);
//	assert(takeKVPTest("hello=world again").token.length == 11);
//	assert(takeKVPTest("hello=world=").type == Token.Type.Error);
//	assert(takeKVPTest("hello=world=again").type == Token.Type.Error);
//	assert(takeKVPTest("hello=world=again thing").type == Token.Type.Error);
//
//	assert(takeKVPTest("\"...\"").token.length == 5);
//	assert(takeKVPTest("'...'").token.length == 5);
//	assert(takeKVPTest("`...`").token.length == 5);
//	assert(takeKVPTest("(...)").token.length == 5);
//	assert(takeKVPTest("[...]").token.length == 5);
//	assert(takeKVPTest("{...}").token.length == 5);
//	assert(takeKVPTest("\"...").type == Token.Type.Error);
//	assert(takeKVPTest("(...").type == Token.Type.Error);
//	assert(takeKVPTest("abc{...}").type == Token.Type.Error);
//	assert(takeKVPTest("{...}abc").type == Token.Type.Error);
//	assert(takeKVPTest("wow=abc{...}").type == Token.Type.Error);
//	assert(takeKVPTest("wee='...'abc").type == Token.Type.Error);
//
//	assert(takeKVPTest("hello='wow'").token.length == 11);
//	assert(takeKVPTest("`wow`=hello").token.length == 11);
//	assert(takeKVPTest("(wow)=[wee]").token.length == 11);
//	assert(takeKVPTest("\"wow\"={wee}=woo").type == Token.Type.Error);
}

/+
Expression takeExpression(ref const(char)[] cmdLine)
{
	Expression r;

	cmdLine = cmdLine.trimCmdLine;

	size_t tokenStart = 0;
	size_t tokenEnd = 0;
	while (tokenEnd < cmdLine.length)
	{
		bool maybeEnd = cmdLine[tokenEnd].isWhitespace;
		if (cmdLine[tokenEnd].isWhitespace)
		{
			// may be the end of the expression, unless it's an operator...
			cmdLine = cmdLine[tokenEnd .. $].trimCmdLine;
			if (cmdLine.length < 0)
				break;
		}

		if (cmdLine[tokenEnd].isAlphaNumeric || cmdLine[tokenEnd] == '_')
			++tokenEnd;

	}

	return r;
}
+/

/+
Token parseToken(const(char)[] cmdLine)
{
	cmdLine = cmdLine.trimCmdLine;
	if (cmdLine.length == 0)
		return Token(Token.Type.Error, "Empty expression");

	size_t tokenEnd = 0;

	char closingChar = '\0';
	if (cmdLine[0] == '"')
		closingChar = '"';
	else if (cmdLine[0] == '(')
		closingChar = ')';
	else if (cmdLine[0] == '[')
		closingChar = ']';
	else if (cmdLine[0] == '{')
		closingChar = '}';
	if (closingChar != '\0')
	{
		++tokenEnd;
		while (tokenEnd < cmdLine.length && cmdLine[tokenEnd] != closingChar)
			++tokenEnd;
		if (tokenEnd == cmdLine.length)
			return Token(Token.Type.Error, "Unclosed string or expression");
		Token.Type ty = closingChar == '"' ? Token.Type.String :
						closingChar == ']' ? Token.Type.Command :
						closingChar == '}' ? Token.Type.Scope :
											 Token.Type.Expression;
		return Token(Token.Type.String, cmdLine[1 .. tokenEnd]);
	}

	// parse a number or an identifier...
	bool isNumber = cmdLine[0].isNumeric;
	if (cmdLine[0] == '-' || cmdLine[0] == '+')
	{
		if (cmdLine.length > 1 && cmdLine[1].isNumeric)
		{
			isNumber = true;
			++tokenEnd;
		}
		else
			return Token(Token.Type.Operator, cmdLine[0 .. 1]);
	}
	if (isNumber)
	{
		++tokenEnd;
		// parse a number, which may include a decimal point...
		while (tokenEnd < cmdLine.length && cmdLine[tokenEnd].isNumeric)
			++tokenEnd;
		size_t numberEnd = tokenEnd;
		if (tokenEnd < cmdLine.length && cmdLine[tokenEnd] == '.')
		{
			++numberEnd;
			while (numberEnd < cmdLine.length && cmdLine[numberEnd].isNumeric)
				++numberEnd;
			if (numberEnd < tokenEnd + 2)
				return Token(Token.Type.Error, "Digit expected after decimal point");
		}
		return Token(Token.Type.Number, cmdLine[0 .. numberEnd]);
	}

	// parse an identifier
	if (cmdLine[0].isAlpha || cmdLine[0] == '_')
	{
		++tokenEnd;
		while (tokenEnd < cmdLine.length && cmdLine[tokenEnd].isAlphaNumeric || cmdLine[tokenEnd] == '_')
			++tokenEnd;
		return Token(Token.Type.Identifier, cmdLine[0 .. tokenEnd]);
	}

	// check for a set of special chars and stuff
	immutable char[8] specialChars = "=$.*/<>:";
	foreach (c; specialChars)
	{
		if (cmdLine[0] == c)
			return Token(Token.Type.Operator, cmdLine[0 .. 1]);
	}

	// otherwise a syntax error...
	return Token(Token.Type.Error, "Syntax error: can't parse expression");
}
+/


Token takePair(ref const(char)[] text)
{
	if (text.length == 0)
		return Token(Token.Type.None, null);

	char close = '\0';
	bool allowNested = void;
	Token.Type ty = void;
	for (size_t i = 0; i < pairs.length; ++i)
	{
		if (text[0] == pairs[i])
		{
			close = closures[i];
			allowNested = i >= 3;
			ty = pairTypes[i];
			break;
		}
	}
	if (close == '\0')
		return Token(Token.Type.None, null);

	const(char)* orig = text.ptr;
	text = text[1..$];
	while (1)
	{
		if (text.length == 0)
			return Token(Token.Type.Error, "Unclosed string or expression");
		if (text[0] == close)
		{
			text = text[1..$];
			return Token(ty, orig[0 .. text.ptr-orig]);
		}
		if (text[0] == '\\' && text.length > 1)
			text = text[2..$];
		else if (allowNested)
		{
			Token iPair = takePair(text);
			if (iPair.type == Token.Type.Error)
				return iPair;
			if (iPair.token.length > 0)
				continue;
		}
		text = text[1..$];
	}
}

Token.Type determineTokenType(const(char)[] token) pure nothrow @nogc
{
	Token.Type type = Token.Type.Token;
	if (token.length == 0)
		type = Token.Type.None;
	else if (token[0].isNumeric || ((token[0] == '+' || token[0] == '-') && token.length > 1 && token[1].isNumeric))
	{
		type = Token.Type.Number;
		bool hasPoint = false;
		foreach (i; 2 .. token.length)
		{
			if (!token[i].isNumeric)
			{
				if (token[i] == '.' && !hasPoint)
					hasPoint = true;
				else
				{
					type = Token.Type.Token;
					break;
				}
			}
		}
	}
	else if (token[0].isAlpha)
	{
		type = Token.Type.Identifier;
		foreach (i; 1 .. token.length)
		{
			if (!token[i].isAlphaNumeric && token[i] != '-')
			{
				type = Token.Type.Token;
				break;
			}
		}
	}
	else if ((token[0] == '\'' || token[0] == '"' || token[0] == '`') && token.length >= 2 && token[$-1] == token[0])
		type = Token.Type.String;
	else if (token[0] == '[' && token[$-1] == ']')
		type = Token.Type.Command;
	else if (token[0] == '(' && token[$-1] == ')')
		type = Token.Type.Expression;
	else if (token[0] == '{' && token[$-1] == '}')
		type = Token.Type.Scope;
	return type;
}

private:

immutable char[6] pairs = "\"'`([{";
immutable char[6] closures = "\"'`)]}";
immutable char[9] nonIdentifierChars = "\"'`()[]{}";
immutable Token.Type[6] pairTypes = [ Token.Type.String, Token.Type.String, Token.Type.String, Token.Type.Expression, Token.Type.Command, Token.Type.Scope ];
