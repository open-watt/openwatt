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
	size_t i = 0;
	for (; i < s.length; ++i)
	{
		if (s[i] == Separator)
			break;
	}
	string t = s[0 .. i].trim!(Trim.Tail);
	s = i < s.length ? s[i+1 .. $].trim!(Trim.Head) : null;
	return t;
}
