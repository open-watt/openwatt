module db.stream;

// for energy meters, Accumulator with time res 100hz and 16bit T is very accurate

enum EndTime = ulong.max;

enum StreamType : ubyte
{
	Auto,
	Accumulator,	// stream of time values between increments
	DenseDelta,	 // regularly cadenced accumulating data
	SparseDelta,	// irregularly cadenced accumulating data
	DenseSample,	// regularly cadenced absolute/noisy data
	SparseSample	// irregularly cadenced absolute/noisy data
}


enum DataType : ubyte
{
	Integer,
	Float,
	String,
	Custom
}


enum Flags : ubyte
{
	AutoType,
	AutoResolution,
}

enum InsertHint : uint
{
	None = 0,
	Sorted = 1 << 0
}

struct BlockTreeNode
{
	ulong startTime, endTime, halfTime;
	BlockMeta* block;
	BlockTreeNode* left, right;
}

struct BlockMeta
{
	ulong startTime, endTime;
	void[] blockData;

	int numSamples;

	// statistics
	int numOoOInserts = 0;
	int numLargesamples = 0;

	BlockMeta* prevBlock, nextBlock;
	BlockTreeNode* treeNode;
}

struct Sample(TimeT = ulong, RecordT = uint)
{
	TimeT time;
	RecordT record;
}

class Stream
{
	string name;

	ulong timeResolution; // 100th's of seconds
	// TODO: stream start time

	StreamType streamType;
	DataType dataType;
	ushort customDataSize;
	Flags flags;

	// TODO: block sizes, elements-per-block, etc...

	BlockTreeNode* root;

	void Insert(TimeT = ulong, RecordT = uint)(Sample!(TimeT, RecordT)[] samples, uint hints = InsertHint.None)
	{
	}

	void Insert(RecordT = uint)(RecordT[] samples, uint hints = InsertHint.None)
	{
	}

}
