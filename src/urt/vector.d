module urt.vector;

struct Vector(T)
{
}


//1111000011001000
// 1 1 0 0 1 0 1 0
//   1   0   1   1
//
// 111100001100100
// 1 1 0 0 1 0 1 0 ^
//
//  11111000111011
//   1   0   1   1 ^
//
//       1       1 ^
//
//               1 ^


struct SmallAllocator(size_t MinAlloc = size_t.sizeof)
{
	enum PageSize = MinAlloc * size_t.sizeof * 8;

	size_t* bitmap;
	ubyte* memory;
	uint numPages = 1;

	void[] alloc(size_t bytes)
	{
		if (bytes > PageSize)
			return null;
		size_t bm = void;
		if (numPages == 0)
			bm = cast(size_t)bitmap;
		


	}





}
