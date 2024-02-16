module util.dbg;

void dbgBreak()
{
	debug asm { int 3; }
}

void dbgAssert(bool condition, string message = null)
{
	debug
	{
		import std.stdio : writeln;
		import core.stdc.stdlib : exit;

		if (!condition)
		{
			writeln(message ? message : "assert failed");
			dbgBreak();
//			exit(-1);
		}
	}
}
