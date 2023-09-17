module sampledb.sampledb;

import std.stdio;

import sampledb.stream;

int main()
{
	Stream stream = new Stream(StreamType.Accumulator, DataType.Integer);

	ushort[] data = [ 10, 1000, 123, 145, 1, 2, 10000, 10 ];

	stream.Insert(data);


	writeln("Hello D World!\n");

    return 0;
}
