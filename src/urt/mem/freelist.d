module urt.mem.freelist;

import urt.lifetime;
import urt.mem.allocator;

nothrow @nogc:


struct FreeList(T, size_t blockSize = 1)
{
    static assert(blockSize > 0, "blockSize must be greater than 0");

    struct Node
    {
        union {
            Node* next = null;
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

    T* alloc(Args...)(auto ref Args args)
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
        emplace(&n.element, forward!args);
        return &n.element;
    }

    void free(T* object)
    {
        Node* n = cast(Node*)object;
        n.element.destroy!false();
        n.next = head;
        head = n;
    }

private:
    Node* head;
    uint itemCount;
}
