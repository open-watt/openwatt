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
nothrow @nogc:
	alias KeyType = K;
	alias ValueType = V; // TODO: . ElementType
	alias KeyValuePair = KVP!(K, V);

	// TODO: copy ctor, move ctor, etc...

//	this(KeyValuePair[] arr)
//	{
//		foreach (ref kvp; arr)
//			insert(kvp.key, kvp.value);
//	}

	~this()
	{
		clear();
	}

	size_t length() const => numNodes;
	bool empty() const => numNodes == 0;

	void clear()
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
	{
		return get(key);
	}

	bool exists(_K)(ref const _K key) const
	{
		return get(key) != null;
	}
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

	Iterator begin()
	{
		return Iterator(pRoot);
	}

	static Iterator end()
	{
		return Iterator();
	}

    int opApply(scope int delegate(ref const K k, ref V v) pure nothrow @nogc dg) pure
    {
        for (Iterator i = begin(); i != end(); ++i)
        {
            int r = dg(i.key, i.value);
            if (r)
                return r;
        }
        return 0;
    }
    int opApply(scope int delegate(ref const K k, ref V v) nothrow @nogc dg)
    {
        for (Iterator i = begin(); i != end(); ++i)
        {
            int r = dg(i.key, i.value);
            if (r)
                return r;
        }
        return 0;
    }

    int opApply(scope int delegate(ref V v) pure nothrow @nogc dg) pure
    {
        for (Iterator i = begin(); i != end(); ++i)
        {
            int r = dg(i.value);
            if (r)
                return r;
        }
        return 0;
    }
    int opApply(scope int delegate(ref V v) nothrow @nogc dg)
    {
        for (Iterator i = begin(); i != end(); ++i)
        {
            int r = dg(i.value);
            if (r)
                return r;
        }
        return 0;
    }

private:
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
		if (!n)
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
		if (!n)
			return;

		destroy(n.left);
		destroy(n.right);

		n.destroy();
		Allocator.instance.freeT(n);

		--numNodes;
	}

	Node* insert(Node* n, Node* newnode)
	{
		// 1.  Perform the normal BST rotation
		if (n == null)
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

			n.destroy();
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

	static Node* minValueNode(Node* n)
	{
		Node* current = n;

		// loop down to find the leftmost leaf
		while (current.left != null)
			current = current.left;

		return current;
	}

	Node* deleteNode(_K)(Node* _pRoot, ref const _K key)
	{
		// STEP 1: PERFORM STANDARD BST DELETE

		if (_pRoot == null)
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
			doDelete(_pRoot);

		return rebalance(_pRoot);
	}

	void doDelete(Node* _pRoot)
	{
		// Node with only one child or no child
		if ((_pRoot.left == null) || (_pRoot.right == null))
		{
			Node* temp = _pRoot.left ? _pRoot.left : _pRoot.right;

			// No child case
			if (temp == null)
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
			// Node with two children: get the inorder successor (smallest
			// in the right subtree)
			Node* temp = minValueNode(_pRoot.right);

			// Copy the inorder successor's data to this Node
			_pRoot.kvp.key = temp.kvp.key;

			// Delete the inorder successor
			_pRoot.right = deleteNode(_pRoot.right, temp.kvp.key);
		}
	}

	Node* rebalance(Node* _pRoot)
	{
		// If the tree had only one Node then return
		if (_pRoot == null)
			return _pRoot;

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

//	static Node* clone(Node* pOld)
//	{
//		if (!pOld)
//			return null;
//
//		Node* pNew = Allocator.instance.allocT!Node(pOld.kvp);
//		pNew.height = pOld.height;
//		pNew.left = clone(pOld.left);
//		pNew.right = clone(pOld.right);
//		return pNew;
//	}

public:
	struct Iterator
	{
	nothrow @nogc:
		this(Node* pRoot)
		{
			this.pRoot = pRoot;

			Node* pLeftMost = pRoot;
			while (pLeftMost && pLeftMost.left)
			{
				stack = stack | (1 << depth);
				depth = depth + 1;
				pLeftMost = pLeftMost.left;
			}
		}

		ref Iterator opUnary(string op : "++")()
		{
			iterateNext(pRoot, null, 0);
			return this;
		}

        ref inout(V) opUnary(string op : "*")() inout
            => value();

		bool opEqual(Iterator rhs) => pRoot == rhs.pRoot && data == rhs.data;

		ref const(K) key() const
		{
			auto node = getNode(stack, depth);
			return node.kvp.key;
		}

		ref inout(V) value() inout
		{
			auto node = getNode(stack, depth);
			return node.kvp.value;
		}

//		KVPRef<const K, const V> operator*() const
//		{
//			return KVPRef<const K, const V>(key(), value());
//		}
//		KVPRef<const K, V> operator*()
//		{
//			return KVPRef<const K, V>(key(), value());
//		}
//		const V* operator.() const
//		{
//			return &value();
//		}
//		V* operator.()
//		{
//			return &value();
//		}

		inout(Node)* getNode(ulong s, ulong d) inout
		{
			inout(Node)* pNode = pRoot;
			for (ulong i = 0; i < d; ++i)
			{
				if (s & (1 << i))
					pNode = pNode.left;
				else
					pNode = pNode.right;
			}
			return pNode;
		}

	private:
		bool iterateNext(Node* pNode, Node* pParent, ulong d)
		{
			if (d < depth)
			{
				Node* pNext = (stack & (1 << d)) ? pNode.left : pNode.right;
				if (!iterateNext(pNext, pNode, d + 1))
					return false;
			}
			else
			{
				if (pNode.right) // Left Most
				{
					depth = depth + 1;
					const(Node)* pLeftMost = pNode.right;
					while (pLeftMost.left)
					{
						stack = stack | (1 << depth);
						depth = depth + 1;
						pLeftMost = pLeftMost.left;
					}
					return false;
				}
			}

			if (depth == 0)
			{
				pRoot = null;
				data = 0;
				return false;
			}

			depth = depth - 1;
			stack = stack & ~(1 << depth);
			if (pParent.right == pNode)
				return true;

			return false;
		}

		ubyte depth() const => data & 0xFF;
		void depth(uint v)
		{
			data = (data & ~0xFF) | (v & 0xFF);
		}

		ulong stack() const => data >> 8;
		void stack(ulong v)
		{
			data = (data & 0xFF) | (v << 8);
		}

		ulong data;
		Node* pRoot;
	}
}

struct AVLTreeNode(K, V)
{
nothrow @nogc:

	AVLTreeNode* left, right;
	KVP!(K, V) kvp;
	int height;

	this() @disable;

	//  this(AVLTreeNode rh)
	//  {
	//	left = rh.left;
	//	right = rh.right;
	//	kvp = rh.kvp.move;
	//	height = rh.height;
	//  }
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
