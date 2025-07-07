module urt.map;

import urt.lifetime;
import urt.kvp;
import urt.mem.allocator;
import urt.util;

nothrow @nogc:


template DefCmp(T)
{
    import urt.algorithm : compare;

//    alias DefCmp(U) = compare!(T, U); // TODO: this should work...

    ptrdiff_t DefCmp(U)(ref const T a, ref const U b)
        => compare(a, b);
}


alias Map(K, V) = AVLTree!(K, V);

struct AVLTree(K, V, alias Pred = DefCmp!K, Allocator = Mallocator)
{
@nogc:
    alias KeyType = K;
    alias ValueType = V; // TODO: . ElementType
    alias KeyValuePair = KVP!(K, V);

    // TODO: copy ctor, move ctor, etc...

//    this(KeyValuePair[] arr)
//    {
//        foreach (ref kvp; arr)
//            insert(kvp.key, kvp.value);
//    }

    ~this() nothrow
    {
        clear();
    }

    size_t length() const nothrow
        => numNodes;
    bool empty() const nothrow
        => numNodes == 0;

    void clear() nothrow
    {
        destroy(pRoot);
        pRoot = null;
    }

    V* insert(_K, _V)(auto ref _K key, auto ref _V val)
    {
        if (get(key))
            return null;
        return &replace(forward!key, forward!val);
    }

/+
  V& insert(K &&key, V &&val)
  {
    if (get(key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(std::move(key), std::move(val));
  }
  V& insert(const K &key, V &&val)
  {
    if (get(key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(key, std::move(val));
  }
  V& insert(K &&key, const V &val)
  {
    if (get(key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(std::move(key), val);
  }
  V& insert(const K &key, const V &val)
  {
    if (get(key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(key, val);
  }

  V& insert(KVP<K, V> &&kvp)
  {
    if (get(kvp.key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(std::move(kvp));
  }
  V& insert(const KVP<K, V> &kvp)
  {
    if (get(kvp.key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(kvp);
  }

  V& tryInsert(const K &key, const V &val)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(key, val);
  }

  V& tryInsert(const K &key, V &&val)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(key, std::move(val));
  }

  V& tryInsert(K &&key, const V &val)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(std::move(key), val);
  }

  V& tryInsert(K &&key, V &&val)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(std::move(key), std::move(val));
  }

  V& tryInsert(const K &key, Delegate<V()> lazy)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(key, lazy());
  }

  V& tryInsert(K &&key, Delegate<V()> lazy)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(std::move(key), lazy());
  }

  V& tryInsert(const KVP<K,V> &kvp)
  {
    V* v = get(kvp.key);
    if (v)
      return *v;
    return replace(kvp.key, kvp.value);
  }

  V& tryInsert(KVP<K, V> &&kvp)
  {
    V* v = get(kvp.key);
    if (v)
      return *v;
    return replace(std::move(kvp.key), std::move(kvp.value));
  }
+/

    ref V replace(_K, _V)(auto ref _K key, auto ref _V val)
    {
        Node* node = cast(Node*)Allocator.instance.alloc(Node.sizeof);
        emplace(&node.kvp, forward!key, forward!val);
        node.left = node.right = null;
        node.height = 1;
        pRoot = insert(pRoot, node);
        return node.kvp.value;
    }
/+
  V& replace(K &&key, V &&val)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(std::move(key), std::move(val));
    node.left = node.right = null;
    node.height = 1;
    pRoot = insert(pRoot, node);
    return node.kvp.value;
  }
  V& replace(const K &key, V &&val)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(key, std::move(val));
    node.left = node.right = null;
    node.height = 1;
    pRoot = insert(pRoot, node);
    return node.kvp.value;
  }
  V& replace(K &&key, const V &val)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(std::move(key), val);
    node.left = node.right = null;
    node.height = 1;
    pRoot = insert(pRoot, node);
    return node.kvp.value;
  }
  V& replace(const K &key, const V &val)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(key, val);
    node.left = node.right = null;
    node.height = 1;
    pRoot = insert(pRoot, node);
    return node.kvp.value;
  }

  V& replace(KVP<K, V> &&kvp)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(std::move(kvp));
    node.left = node.right = null;
    node.height = 1;
    pRoot = insert(pRoot, node);
    return node.kvp.value;
  }
  V& replace(const KVP<K, V> &kvp)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(kvp);
    node.left = node.right = null;
    node.height = 1;
    pRoot = insert(pRoot, node);
    return node.kvp.value;
  }
+/

    void remove(_K)(ref const _K key)
    {
        pRoot = deleteNode(pRoot, key);
    }

    inout(V)* get(_K)(ref const _K key) inout
    {
        inout(Node)* n = find(pRoot, key);
        return n ? &n.kvp.value : null;
    }

    ref inout(V) opIndex(_K)(ref const _K key) inout
    {
        inout(V)* pV = get(key);
        assert(pV, "Element not found");
        return *pV;
    }

    // TODO: should an assignment expression return anything? I think not...
    void opIndexAssign(_V)(auto ref _V value, ref const K key)
    {
        replace(key, forward!value);
    }

    inout(V)* opBinaryRight(string op : "in", _K)(ref const _K key) inout
        => get(key);

    bool exists(_K)(ref const _K key) const
        => get(key) != null;
/+
    AVLTree<K, V>& operator =(const AVLTree<K, V> &rh)
    {
        if (this != &rh)
        {
            this.~AVLTree();
            epConstruct(this) AVLTree<K, V>(rh);
        }
        return *this;
    }

    AVLTree<K, V>& operator =(AVLTree<K, V> &&rval)
    {
        if (this != &rval)
        {
            this.~AVLTree();
            epConstruct(this) AVLTree<K, V>(std::move(rval));
        }
        return *this;
    }
+/

    // TODO: why don't the const overloads work properly?
    auto keys() const nothrow
        => Range!(IterateBy.Keys, true)(pRoot);
    auto values() nothrow
        => Range!(IterateBy.Values)(pRoot);
//    auto values() const nothrow
//        => Range!(IterateBy.Values, true)(pRoot);

    auto opIndex() nothrow
        => Range!(IterateBy.KVP)(pRoot);
//    auto opIndex() const nothrow
//        => Range!(IterateBy.KVP, true)(pRoot);

private:
nothrow:
    alias Node = AVLTreeNode!(K, V);

    size_t numNodes = 0;
    Node* pRoot = null;

    static int height(const(Node)* n) pure
    {
        return n ? n.height : 0;
    }

    static int maxHeight(const(Node)* n) pure
    {
        if (!n)
            return 0;
        if (n.left)
        {
            if (n.right)
                return max(n.left.height, n.right.height);
            else
                return n.left.height;
        }
        if (n.right)
            return n.right.height;
        return 0;
    }

    static int getBalance(Node* n) pure
    {
        return n ? height(n.left) - height(n.right) : 0;
    }

    static Node* rightRotate(Node* y) pure
    {
        Node* x = y.left;
        Node* T2 = x.right;

        // Perform rotation
        x.right = y;
        y.left = T2;

        // Update heights
        y.height = maxHeight(y) + 1;
        x.height = maxHeight(x) + 1;

        // Return new root
        return x;
    }

    static Node* leftRotate(Node* x) pure
    {
        Node* y = x.right;
        Node* T2 = y.left;

        // Perform rotation
        y.left = x;
        x.right = T2;

        //  Update heights
        x.height = maxHeight(x) + 1;
        y.height = maxHeight(y) + 1;

        // Return new root
        return y;
    }

    static inout(Node)* find(_K)(inout(Node)* n, ref const _K key)
    {
        if (n is null)
            return null;
        ptrdiff_t c = Pred(n.kvp.key, key);
        if (c > 0)
            return find(n.left, key);
        if (c < 0)
            return find(n.right, key);
        return n;
    }

    void destroy(Node* n)
    {
        if (n is null)
            return;

        destroy(n.left);
        destroy(n.right);

        Allocator.instance.freeT(n);

        --numNodes;
    }

    Node* insert(Node* n, Node* newnode)
    {
        // 1.  Perform the normal BST rotation
        if (n is null)
        {
            ++numNodes;
            return newnode;
        }

        ptrdiff_t c = Pred(newnode.kvp.key, n.kvp.key);
        if (c < 0)
            n.left = insert(n.left, newnode);
        else if (c > 0)
            n.right = insert(n.right, newnode);
        else
        {
            newnode.left = n.left;
            newnode.right = n.right;
            newnode.height = n.height;

            Allocator.instance.freeT(n);

            return newnode;
        }

        // 2. Update height of this ancestor Node
        n.height = maxHeight(n) + 1;

        // 3. get the balance factor of this ancestor Node to check whether
        //    this Node became unbalanced
        int balance = getBalance(n);

        // If this Node becomes unbalanced, then there are 4 cases

        if (balance > 1)
        {
            ptrdiff_t lc = Pred(newnode.kvp.key, n.left.kvp.key);
            // Left Left Case
            if (lc < 0)
                return rightRotate(n);

            // Left Right Case
            if (lc > 0)
            {
                n.left = leftRotate(n.left);
                return rightRotate(n);
            }
        }

        if (balance < -1)
        {
            ptrdiff_t rc = Pred(newnode.kvp.key, n.right.kvp.key);

            // Right Right Case
            if (rc > 0)
                return leftRotate(n);

            // Right Left Case
            if (rc < 0)
            {
                n.right = rightRotate(n.right);
                return leftRotate(n);
            }
        }

        // return the (unchanged) Node pointer
        return n;
    }

    Node* deleteNode(_K)(Node* _pRoot, ref const _K key)
    {
        // STEP 1: PERFORM STANDARD BST DELETE

        if (_pRoot is null)
            return _pRoot;

        ptrdiff_t c = Pred(_pRoot.kvp.key, key);

        // If the key to be deleted is smaller than the _pRoot's key,
        // then it lies in left subtree
        if (c > 0)
            _pRoot.left = deleteNode(_pRoot.left, key);

        // If the key to be deleted is greater than the _pRoot's key,
        // then it lies in right subtree
        else if (c < 0)
            _pRoot.right = deleteNode(_pRoot.right, key);

        // if key is same as _pRoot's key, then this is the Node
        // to be deleted
        else
            _pRoot = doDelete(_pRoot);

        return rebalance(_pRoot);
    }

    Node* doDelete(Node* _pRoot)
    {
        // Node with only one child or no child
        if ((_pRoot.left is null) || (_pRoot.right is null))
        {
            Node* temp = _pRoot.left ? _pRoot.left : _pRoot.right;

            // No child case
            if (temp is null)
            {
                temp = _pRoot;
                _pRoot = null;
            }
            else // One child case
            {
                // TODO: FIX THIS!!
                // this is copying the child node into the parent node because there is no parent pointer
                // DO: add parent pointer, then fix up the parent's child pointer to the child, and do away with this pointless copy!
                *_pRoot = (*temp).move; // Copy the contents of the non-empty child
            }

            Allocator.instance.freeT(temp);

            --numNodes;
        }
        else
        {
            // Node with two children: we replace 'this' node with the next one in sequence...

            // get the in-order successor: the 'next' item is the far left node on the right hand side)
            Node* next = _pRoot.right;
            while (next.left !is null) // find the leftmost leaf
                next = next.left;

            // Copy the in-order successor's data to this Node
            _pRoot.kvp.key = next.kvp.key; // we can't move the key, because deleteNode still needs to be able to find it
            _pRoot.kvp.value = next.kvp.value.move;

            // Delete the node we just shifted
            _pRoot.right = deleteNode(_pRoot.right, next.kvp.key);
        }

        return _pRoot;
    }

    Node* rebalance(Node* _pRoot)
    {
        // If the tree had only one Node then return
        if (_pRoot is null)
            return null;

        // STEP 2: UPDATE HEIGHT OF THE CURRENT NODE
        _pRoot.height = max(height(_pRoot.left), height(_pRoot.right)) + 1;

        // STEP 3: GET THE BALANCE FACTOR OF THIS NODE (to check whether
        //  this Node became unbalanced)
        int balance = getBalance(_pRoot);

        // If this Node becomes unbalanced, then there are 4 cases

        // Left Left Case
        if (balance > 1 && getBalance(_pRoot.left) >= 0)
            return rightRotate(_pRoot);

        // Left Right Case
        if (balance > 1 && getBalance(_pRoot.left) < 0)
        {
            _pRoot.left = leftRotate(_pRoot.left);
            return rightRotate(_pRoot);
        }

        // Right Right Case
        if (balance < -1 && getBalance(_pRoot.right) <= 0)
            return leftRotate(_pRoot);

        // Right Left Case
        if (balance < -1 && getBalance(_pRoot.right) > 0)
        {
            _pRoot.right = rightRotate(_pRoot.right);
            return leftRotate(_pRoot);
        }

        return _pRoot;
    }

//    static Node* clone(Node* pOld)
//    {
//        if (!pOld)
//            return null;
//
//        Node* pNew = Allocator.instance.allocT!Node(pOld.kvp);
//        pNew.height = pOld.height;
//        pNew.left = clone(pOld.left);
//        pNew.right = clone(pOld.right);
//        return pNew;
//    }

public:
    enum IterateBy
    {
        Keys,
        Values,
        KVP
    }
    struct Range(IterateBy type, bool const_ = false)
    {
    nothrow @nogc:
        import urt.array;

        static if (const_)
            alias PN = const(Node)*;
        else
            alias PN = Node*;

        PN n;
        Array!(PN) stack;

        this(PN root)
        {
            if (root)
            {
                stack.reserve(root.height - 1);
                n = getLeft(root);
            }
        }

        bool empty() const pure
            => n is null;

        static if (type == IterateBy.Keys)
        {
            ref const(K) front() const pure
                => n.kvp.key;
        }
        else
        {
            static if (const_)
            {
                ref auto front() const
                {
                    static if (type == IterateBy.Values)
                        return n.kvp.value;
                    else
                    {
                        struct KV
                        {
                            const PN n;
                            ref const(K) key() @property const pure
                                => n.kvp.key;
                            ref const(V) value() @property const pure
                                => n.kvp.value;
                        }
                        return KV(n);
                    }
                }
            }
            else
            {
                ref auto front()
                {
                    static if (type == IterateBy.Values)
                        return n.kvp.value;
                    else
                    {
                        struct KV
                        {
                            PN n;
                            ref const(K) key() @property const pure
                                => n.kvp.key;
//                            ref const(V) value() @property const pure
//                                => n.kvp.value;
                            ref V value() @property pure
                                => n.kvp.value;
                        }
                        return KV(n);
                    }
                }
            }
        }

        void popFront()
        {
            if (n.right)
                n = getLeft(n.right);
            else
                n = !stack.empty ? stack.popBack() : null;
        }

    private:
        PN getLeft(PN node)
        {
            while (node.left)
            {
                stack ~= node;
                node = node.left;
            }
            return node;
        }
    }
}

struct AVLTreeNode(K, V)
{
nothrow @nogc:

    AVLTreeNode* left, right;
    KVP!(K, V) kvp;
    int height;

    this() @disable;

//    this(AVLTreeNode rh)
//    {
//        left = rh.left;
//        right = rh.right;
//        kvp = rh.kvp.move;
//        height = rh.height;
//    }
    this(ref AVLTreeNode rh)
    {
        left = rh.left;
        right = rh.right;
        kvp = rh.kvp;
        height = rh.height;
    }

    ref AVLTreeNode opAssign(ref AVLTreeNode rh)
    {
        this.destroy();
        emplace(&this, rh);
        return this;
    }

    ref AVLTreeNode opAssign(AVLTreeNode rh)
    {
        this.destroy();
        emplace(&this, rh.move);
        return this;
    }
}

/+
template<typename K, typename V, typename PredFunctor, typename Allocator>
ptrdiff_t epStringify(Slice<char> buffer, String epUnusedParam(format), const AVLTree<K, V, PredFunctor, Allocator> &tree, const VarArg* epUnusedParam(pArgs))
{
    size_t offset = 0;
    if (buffer)
        offset += String("{ ").copyTo(buffer);
    else
        offset += String("{ ").length;

    bool bFirst = true;
    for (auto &&kvp : tree)
    {
        if (!bFirst)
        {
            if (buffer)
                offset += String(", ").copyTo(buffer.drop(offset));
            else
                offset += String(", ").length;
        }
        else
            bFirst = false;

        if (buffer)
            offset += epStringify(buffer.drop(offset), null, kvp, null);
        else
            offset += epStringify(null, null, kvp, null);
    }

    if (buffer)
        offset += String(" }").copyTo(buffer.drop(offset));
    else
        offset += String(" }").length;

    return offset;
}
+/

//// Range retrieval
//template <typename K, typename V, typename P, typename A>
//TreeRange<AVLTree<K, V, P, A>> range(const AVLTree<K, V, P, A> &input) { return TreeRange<AVLTree<K, V, P, A>>(input); }



unittest
{
    alias TestAVLTree = AVLTree!(int, int);
    alias TestAVLTreeCIP = AVLTree!(int, const(int)*);

    static assert(is(TestAVLTree.KeyType == int), "IndexType failed!");

    static assert(is(TestAVLTree.ValueType == int), "ElementType failed!");
    static assert(is(TestAVLTreeCIP.ValueType == const(int)*), "ElementType failed!");

    // Basic insertion and retrieval
    {
        TestAVLTree map;
        assert(map.empty());
        assert(map.length == 0);

        map.insert(1, 10);
        assert(!map.empty());
        assert(map.length == 1);
        assert(map.get(1) !is null && *map.get(1) == 10);
        assert(map[1] == 10);
        assert(1 in map);
        assert(map.exists(1));

        map.insert(2, 20);
        assert(map.length == 2);
        assert(map.get(2) !is null && *map.get(2) == 20);
        assert(map[2] == 20);
        assert(2 in map);

        // Test inserting duplicate key (should be ignored)
        auto pVal = map.insert(1, 11);
        assert(pVal is null); // Insert should fail if key exists
        assert(map.length == 2);
        assert(map[1] == 10); // Value should remain unchanged

        // Test non-existent key
        assert(map.get(3) is null);
        assert(3 !in map);
        assert(!map.exists(3));
    }

    // Replace and opIndexAssign
    {
        TestAVLTree map;
        map.replace(5, 50);
        assert(map.length == 1);
        assert(map[5] == 50);

        map.replace(5, 55); // Replace existing key
        assert(map.length == 1);
        assert(map[5] == 55);

        map[6] = 60; // opIndexAssign for new key
        assert(map.length == 2);
        assert(map[6] == 60);

        map[6] = 66; // opIndexAssign for existing key
        assert(map.length == 2);
        assert(map[6] == 66);
    }

    // Removal
    {
        TestAVLTree map;
        map.insert(10, 100);
        map.insert(5, 50);
        map.insert(15, 150);
        map.insert(3, 30);
        map.insert(7, 70);
        map.insert(12, 120);
        map.insert(17, 170);
        assert(map.length == 7);

        map.remove(5); // Remove node with two children
        assert(map.length == 6);
        assert(map.get(5) is null);
        assert(map.exists(3));
        assert(map.exists(7));

        map.remove(3); // Remove leaf node
        assert(map.length == 5);
        assert(map.get(3) is null);

        map.remove(17); // Remove leaf node
        assert(map.length == 4);
        assert(map.get(17) is null);

        map.remove(10); // Remove root node
        assert(map.length == 3);
        assert(map.get(10) is null);
        assert(map.exists(7));
        assert(map.exists(15));
        assert(map.exists(12));

        map.remove(15);
        assert(map.length == 2);
        assert(map.get(15) is null);

        map.remove(7);
        assert(map.length == 1);
        assert(map.get(7) is null);

        map.remove(12);
        assert(map.length == 0);
        assert(map.empty());
        assert(map.get(12) is null);

        // Remove non-existent key
        map.remove(100);
        assert(map.length == 0);
        assert(map.empty());
    }

    // Clear
    {
        TestAVLTree map;
        map.insert(1, 1);
        map.insert(2, 2);
        assert(map.length == 2);
        map.clear();
        assert(map.length == 0);
        assert(map.empty());
        assert(map.get(1) is null);
        assert(map.get(2) is null);
    }

    // Iteration (opApply)
    {
        TestAVLTree map;
        map.insert(3, 30);
        map.insert(1, 10);
        map.insert(2, 20);
        map.insert(4, 40);

        int sumKeys = 0;
        int sumValues = 0;
        int count = 0;

        // Iterate key-value pairs
        foreach (kv; map)
        {
            sumKeys += kv.key;
            sumValues += kv.value;
            count++;
        }

        assert(count == 4);
        assert(sumKeys == 1 + 2 + 3 + 4);
        assert(sumValues == 10 + 20 + 30 + 40);

        sumValues = 0;
        count = 0;
        // Iterate values only
        foreach (v; map.values)
        {
            sumValues += v;
            count++;
        }
        assert(count == 4);
        assert(sumValues == 10 + 20 + 30 + 40);

        // Test stopping iteration
        count = 0;
        foreach (k; map.keys)
        {
            count++;
            if (k == 2)
                break; // Stop when key is 2
        }
        assert(count == 2); // Should stop after 1 and 2
    }

    // Iteration (Iterator struct)
    {
        TestAVLTree map;
        map.insert(3, 30);
        map.insert(1, 10);
        map.insert(2, 20);
        map.insert(4, 40);

        foreach (kvp; map) // Uses Iterator internally
        {
            // Note: D's foreach over structs with opApply might not directly use the Iterator struct
            // but opApply tests cover the iteration logic.
            // This loop tests if the basic range primitives work.
            // A direct Iterator test:
        }

        // Test empty map iteration
        TestAVLTree emptyMap;
        assert(emptyMap[].empty);
    }

    // Test with string keys
    {
        alias StringMap = AVLTree!(const(char)[], int);
        StringMap map;

        map.insert("banana", 1);
        map.insert("apple", 2);
        map.insert("cherry", 3);

        assert(map.length == 3);
        assert(map["apple"] == 2);
        assert(map["banana"] == 1);
        assert(map["cherry"] == 3);
        assert("banana" in map);
        assert("grape" !in map);

        map.remove("banana");
        assert(map.length == 2);
        assert("banana" !in map);
        assert(map["apple"] == 2);
        assert(map["cherry"] == 3);

        int count = 0;
        foreach (kv; map)
        {
            count++;
        }
        assert(count == 2);
    }
}
