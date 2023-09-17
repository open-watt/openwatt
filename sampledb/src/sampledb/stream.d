module sampledb.stream;

import std.algorithm : max;
import sampledb.block;
import sampledb.realtime;

public import sampledb.block : StreamType, DataType;

enum Flags : ubyte
{
	AutoType = 1 << 0,
	AutoResolution = 1 << 1,
}


struct BlockTreeNode
{
	RealTime startTime, endTime, halfTime;
	BlockMeta* block;
	BlockTreeNode* left, right;
}

class Stream
{
	string name;

	ulong timeResolution; // 100th's of seconds
	RealTime streamStartRealTime;

	StreamType streamType;
	DataType dataType;
	ushort customDataSize;
	ubyte flags;

	size_t sampleSize;
	size_t elementsPerBlock;

	BlockTreeNode* root;
	BlockMeta* tail;

	this(StreamType streamType, DataType dataType, uint millisecondsPerSample = 10, ubyte flags = Flags.AutoType | Flags.AutoType)
	{
		timeResolution = millisecondsPerSample / 10;

		this.streamType = streamType;
		this.dataType = dataType;
		customDataSize = 0;
		this.flags = flags;

		// assume int or float for now
		sampleSize = ushort.sizeof;
		if (streamType >= StreamType.DenseSample)
			sampleSize = Sample!(ushort, short).sizeof;

		enum maxBlockSize = 1024 * 1024 * 1; // 1 meg blocks?
		const samplesPerMinute = 6000 / timeResolution;
		const samplesPer15Min = 6000 * 15 / timeResolution;
		const samplesPerHour = 6000 * 60 / timeResolution;
		const samplesPerDay = 6000 * 60 * 24 / timeResolution;

		if (sampleSize * (6000 * 60 * 24 / timeResolution) < maxBlockSize)
			elementsPerBlock = 6000 * 60 * 24 / timeResolution;
		else if (sampleSize * (6000 * 60 / timeResolution) < maxBlockSize)
			elementsPerBlock = 6000 * 60 / timeResolution;
		else if (sampleSize * (6000 * 15 / timeResolution) < maxBlockSize)
			elementsPerBlock = 6000 * 15 / timeResolution;
		else
			elementsPerBlock = 6000 / timeResolution;

		root = new BlockTreeNode;
		root.startTime = RealTime.min;
		root.endTime = RealTime.max;
		root.halfTime = RealTime.max;
		root.left = null;
		root.right = null;
		root.block = new BlockMeta;
		tail = root.block;

		root.block.Allocate(streamType, dataType, sampleSize * elementsPerBlock, root); // TODO: some extra for occasional over-size samples?
	}

	void Insert(TimeT = ulong, RecordT = uint)(Sample!(TimeT, RecordT)[] samples, uint hints = InsertHint.None)
	{
		// TODO: only dense streams for now...
		assert(0);
	}

	void Insert(RecordT = uint)(RecordT[] samples, uint hints = InsertHint.None)
	{
		switch (streamType)
		{
		case StreamType.Accumulator:
			assert(RecordT.stringof == "ushort");

			BlockMeta* block = tail;

			while (samples)
			{
				samples = block.Insert(samples, hints);

				// TODO: if there are more samples, then we need a new block...
				assert(!samples);
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
	}

private:

}
