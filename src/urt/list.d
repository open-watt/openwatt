module urt.list;

struct List(T, bool DL = false, bool Invasive = false)
{
    static if (!Invasive)
    {
        struct Item
        {
            Item* next;
            static if (DL)
                Item* prev;
            T value;
        }
        alias ListItem = Item;
    }
    else
        alias ListItem = T;

    struct Iterator
    {
        ListItem* current;
    }

    ListItem* head;
    static if (DL)
        ListItem* tail;
    size_t length;

    // TODO: allocator...
}

alias InvasiveList(T) = List!(T, false, true);
alias DoubleLinkedList(T) = List!(T, true, false);
alias InvasiveDoubleLinkedList(T) = List!(T, true, true);
