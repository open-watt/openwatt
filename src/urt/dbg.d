module urt.dbg;


void breakpoint() pure nothrow @nogc
{
	debug asm pure nothrow @nogc
	{
		int 3;
	}
}


private:

package(urt) void setupAssertHandler()
{
	import core.exception : assertHandler;
	assertHandler = &urt_assert;
}

void urt_assert(string file, size_t line, string msg) nothrow @nogc
{
	import core.stdc.stdlib : exit;

	debug
	{
		import core.stdc.stdio;

		if (msg.length == 0)
			msg = "Assertion failed";

		version (Windows)
		{
			import core.sys.windows.winbase;
			char[1024] buffer;
			_snprintf(buffer.ptr, buffer.length, "%.*s(%d): %.*s\n", cast(int)file.length, file.ptr, cast(int)line, cast(int)msg.length, msg.ptr);
			OutputDebugStringA(buffer.ptr);

			// Windows can have it at stdout aswell?
			printf("%.*s(%d): %.*s\n", cast(int)file.length, file.ptr, cast(int)line, cast(int)msg.length, msg.ptr);
		}
		else
		{
			// TODO: write to stderr would be better...
			printf("%.*s(%d): %.*s\n", cast(int)file.length, file.ptr, cast(int)line, cast(int)msg.length, msg.ptr);
		}

		breakpoint();
//		exit(-1);
	}
	else
		exit(-1);
}
