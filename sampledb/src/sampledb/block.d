module sampledb.block;

import sampledb.realtime;
import sampledb.stream : BlockTreeNode;

// for energy meters, Accumulator with time res 100hz and 16bit T is very accurate

enum EndTime = ulong.max;

enum StreamType : ubyte
{
	Auto,
	Accumulator, // stream of time values between increments
	DenseDelta, // regularly cadenced accumulating data
	SparseDelta, // irregularly cadenced accumulating data
	DenseSample, // regularly cadenced absolute/noisy data
	SparseSample // irregularly cadenced absolute/noisy data
}

enum DataType : ubyte
{
	Integer,
	Float,
	String,
	Custom
}

enum InsertHint : uint
{
	None = 0,
	Sorted = 1 << 0
}


struct Sample(TimeT = ushort, RecordT = short)
{
	TimeT time;
	RecordT record;
}

struct BlockMeta
{
public:

	void Allocate(StreamType streamType, DataType dataType, size_t bytes, BlockTreeNode* node = null)
	{
		this.streamType = streamType;
		this.dataType = dataType;

		blockData = new void[bytes]; // TODO: some extra for occasional over-size samples?
		treeNode = node;
	}
	
	void Insert(TimeT = ulong, RecordT = uint)(Sample!(TimeT, RecordT)[] samples, uint hints = InsertHint.None)
	{
		// TODO: only dense streams for now...
		assert(0);
	}

	RecordT[] Insert(RecordT = uint)(RecordT[] samples, uint hints = InsertHint.None)
	{
		switch (streamType)
		{
			case StreamType.Accumulator:
				assert(RecordT.stringof == "ushort");

				// count the ticks...
				ulong newOffset = timeOffset;
				foreach (tick; samples)
				{
					newOffset += tick;
				}
				timeOffset = newOffset;
				// TODO: did we overflow an hour? a day? what block res to use?

				ushort[] data = GetTail!ushort();
				if (data.length < samples.length)
				{
					data[0 .. samples.length] = samples[];
					endValue += samples.length;
				}
				else
				{
					// overflow the block...
					assert(false);
				}
				break;
			case StreamType.DenseDelta:
				break;
			case StreamType.SparseDelta:
				break;
			case StreamType.DenseSample:
				break;
			case StreamType.SparseSample:
				break;
			default:
				assert(0);
		}

		return null;
	}

private:
	StreamType streamType;
	DataType dataType;

	RealTime startTime = RealTime.min, endTime = RealTime.max;

	void[] blockData = null;
	size_t dataLen = 0;
	ulong timeOffset = 0;

	int numSamples = 0;

	ulong startValue = 0, endValue = 0;
	double startValueF = 0, endValueF = 0;

	// statistics
	int numOoOInserts = 0;
	int numLargesamples = 0;

	BlockMeta* nextBlock = null, prevBlock = null;
	BlockTreeNode* treeNode = null;

	T[] GetData(T)()
	{
		return cast(T[])blockData[0 .. $];
	}
	T[] GetTail(T)()
	{
		return cast(T[])blockData[dataLen .. $];
	}
}
