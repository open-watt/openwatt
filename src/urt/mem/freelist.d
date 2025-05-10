module urt.mem.freelist;

import urt.lifetime;
import urt.mem.allocator;

nothrow @nogc:


struct FreeList(T, size_t blockSize = 1)
{
    static assert(blockSize > 0, "blockSize must be greater than 0");

    static if (is(T == class))
        alias PtrTy = T;
    else
        alias PtrTy = T*;

    struct Node
    {
        union {
            Node* next = null;
            static if (is(T == class))
            {
                align(__traits(classInstanceAlignment, T))
                void[__traits(classInstanceSize, T)] element = void;
            }
            else
                T element = void;
        }
    }

    ~this()
    {
        if (blockSize == 1)
        {
            while (head)
            {
                Node* n = head;
                head = head.next;
                defaultAllocator().freeT(n);
                --itemCount;
            }
        }
        else
        {
            assert(false, "TODO: find the lowest pointer; free it as a block; repeat until all blocks are freed");
        }

        assert(itemCount == 0, "Free list has unfreed items!");
    }

    PtrTy alloc(Args...)(auto ref Args args)
    {
        Node* n = head;
        if (!n)
        {
            static if (blockSize == 1)
            {
                n = defaultAllocator().allocT!Node();
                ++itemCount;
            }
            else
            {
                Node[] items = cast(Node[0 .. blockSize])defaultAllocator().alloc(Node.sizeof * blockSize, Node.alignof);
                foreach (i; 1 .. blockSize)
                    items[i].next = i == blockSize - 1 ? head : &items[i + 1];
                head = &items[1];
                n = &items[0];
                itemCount += blockSize;
            }
        }
        else
            head = n.next;
        // TODO: when placement new is available...
//        static if (CanPlacementNew!(T, args))
//            return new(n.element) T(forward!args);
//        else
        {
            emplace(&n.element, forward!args);
            return &n.element;
        }
    }

    void free(PtrTy object)
    {
        static if (is(T == class))
            object.destroy!false();
        else
            (*object).destroy!false();
        Node* n = cast(Node*)object;
        n.next = head;
        head = n;
    }

private:
    Node* head;
    uint itemCount;
}
