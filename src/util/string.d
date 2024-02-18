module util.string;

enum Trim
{
	Head, Tail, Both
}

bool empty(T)(T[] arr)
{
	return arr.length == 0;
}

string trim(Trim t = Trim.Both)(string s)
{
	size_t i = 0, j = s.length;
	static if (t != Trim.Tail)
	{
		for (; i < s.length; ++i)
		{
			if (s[i] != ' ' && s[i] != '\t')
				break;
		}
	}
	static if (t != Trim.Head)
	{
		for (; j > 0; --j)
		{
			if (s[j-1] != ' ' && s[j-1] != '\t')
				break;
		}
	}
	return s[i..j];
}

string takeLine(ref string s)
{
	for (size_t i = 0; i < s.length; ++i)
	{
		if (s[i] == '\n')
		{
			string t = s[0 .. i];
			s = s[i + 1 .. $];
			return t;
		}
		else if (s.length > i+1 && s[i] == '\r' && s[i+1] == '\n')
		{
			string t = s[0 .. i];
			s = s[i + 2 .. $];
			return t;
		}
	}
	string t = s;
	s = s[$ .. $];
	return t;
}

string trimComment(char Delimiter)(string s)
{
	size_t i = 0;
	for (; i < s.length; ++i)
	{
		if (s[i] == Delimiter)
			break;
	}
	while(i > 0 && (s[i-1] == ' ' || s[i-1] == '\t'))
		--i;
	return s[0 .. i];
}

string split(char Separator)(ref string s)
{
	int inQuotes = 0;
	size_t i = 0;
	for (; i < s.length; ++i)
	{
		if (s[i] == Separator && !inQuotes)
			break;
		if (s[i] == '"' && !(inQuotes & 0x6))
			inQuotes = 1 - inQuotes;
		else if (s[i] == '\'' && !(inQuotes & 0x5))
			inQuotes = 2 - inQuotes;
		else if (s[i] == '`' && !(inQuotes & 0x3))
			inQuotes = 4 - inQuotes;
	}
	string t = s[0 .. i].trim!(Trim.Tail);
	s = i < s.length ? s[i+1 .. $].trim!(Trim.Head) : null;
	return t;
}

string split(Separator...)(ref string s, ref char sep)
{
	sep = '\0';
	int inQuotes = 0;
	size_t i = 0;
	loop: for (; i < s.length; ++i)
	{
		static foreach (S; Separator)
		{
			static assert(is(typeof(S) == char), "Only single character separators supported");
			if (s[i] == S && !inQuotes)
			{
				sep = s[i];
				break loop;
			}
		}
		if (s[i] == '"' && !(inQuotes & 0x6))
			inQuotes = 1 - inQuotes;
		else if (s[i] == '\'' && !(inQuotes & 0x5))
			inQuotes = 2 - inQuotes;
		else if (s[i] == '`' && !(inQuotes & 0x3))
			inQuotes = 4 - inQuotes;
	}
	string t = s[0 .. i].trim!(Trim.Tail);
	s = i < s.length ? s[i+1 .. $].trim!(Trim.Head) : null;
	return t;
}

string unQuote(string s)
{
	if (s.empty)
		return s;
	if (s[0] == '"' && s[$-1] == '"' || s[0] == '\'' && s[$-1] == '\'')
		return s[1 .. $-1].unEscape;
	else if (s[0] == '`' && s[$-1] == '`')
		return s[1 .. $-1];
	return s;
}

string unEscape(string s)
{
	if (s.empty)
		return null;

	char[1024] buffer;
	char[] t;
	size_t len = 0;

	for (size_t i = 0; i < s.length; ++i)
	{
		if (s[i] == '\\')
		{
			if (!t)
			{
				if (s.length > buffer.sizeof)
					t = new char[s.length];
				else
					t = buffer;
				t[0..i] = s[0..i];
				len = i;
			}

			if (s.length > ++i)
			{
				switch (s[i])
				{
					case '0':	t[len++] = '\0';	break;
					case 'n':	t[len++] = '\n';	break;
					case 'r':	t[len++] = '\r';	break;
					case 't':	t[len++] = '\t';	break;
//					case '\\':	t[len++] = '\\';	break;
//					case '\'':	t[len++] = '\'';	break;
					default:	t[len++] = s[i];
				}
			}
		}
		else if (t)
			t[len++] = s[i];
	}
	return t ? t[0..len].idup : s;
}

bool wildcardMatch(string wildcard, string value)
{
	// TODO: write this function...

	// HACK: we just use this for tail wildcards right now...
	for (size_t i = 0; i < wildcard.length; ++i)
	{
		if (wildcard[i] == '*')
			return true;
		if (wildcard[i] != value[i])
			return false;
	}
	return wildcard.length == value.length;
}
