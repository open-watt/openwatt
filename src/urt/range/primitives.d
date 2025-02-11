module urt.range.primitives;

import urt.traits;


enum bool isInputRange(R) =
    is(typeof(R.init) == R)
    && is(typeof((R r) { return r.empty; } (R.init)) == bool)
    && (is(typeof((return ref R r) => r.front)) || is(typeof(ref (return ref R r) => r.front)))
    && !is(typeof((R r) { return r.front; } (R.init)) == void)
    && is(typeof((R r) => r.popFront));
enum bool isInputRange(R, E) =
    .isInputRange!R && isQualifierConvertible!(ElementType!R, E);

enum bool isForwardRange(R) = isInputRange!R
    && is(typeof((R r) { return r.save; } (R.init)) == R);
enum bool isForwardRange(R, E) =
    .isForwardRange!R && isQualifierConvertible!(ElementType!R, E);

enum bool isBidirectionalRange(R) = isForwardRange!R
    && is(typeof((R r) => r.popBack))
    && (is(typeof((return ref R r) => r.back)) || is(typeof(ref (return ref R r) => r.back)))
    && is(typeof(R.init.back.init) == ElementType!R);
enum bool isBidirectionalRange(R, E) =
    .isBidirectionalRange!R && isQualifierConvertible!(ElementType!R, E);

enum bool isRandomAccessRange(R) =
    is(typeof(lvalueOf!R[1]) == ElementType!R)
    && !(isAutodecodableString!R && !isAggregateType!R)
    && isForwardRange!R
    && (isBidirectionalRange!R || isInfinite!R)
    && (hasLength!R || isInfinite!R)
    && (isInfinite!R || !is(typeof(lvalueOf!R[$ - 1]))
        || is(typeof(lvalueOf!R[$ - 1]) == ElementType!R));
enum bool isRandomAccessRange(R, E) =
    .isRandomAccessRange!R && isQualifierConvertible!(ElementType!R, E);


// is this in the wrong place? should this be a general traits for arrays and stuff too?
template ElementType(R)
{
    static if (is(typeof(lvalueOf!R.front)))
        alias ElementType = typeof(lvalueOf!R.front);
    else static if (is(R : T[], T))
        alias ElementType = T;
    else
        ElementType = void;
}
