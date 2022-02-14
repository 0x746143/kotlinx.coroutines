/*
 * Copyright 2016-2022 JetBrains s.r.o. Use of this source code is governed by the Apache 2.0 license.
 */

package kotlinx.coroutines.channels


import kotlinx.atomicfu.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlinx.coroutines.internal.*
import kotlinx.coroutines.selects.*
import kotlin.coroutines.intrinsics.intercepted
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn
import kotlin.coroutines.resume
import kotlin.jvm.*

public open class RendezvousChannelEuropar<E> : Channel<E> {
    protected open fun onReceiveEnqueued() {}
    protected open fun onReceiveDequeued() {}

    // Waiting queue node
    internal class Node(@JvmField val segmentSize: Int, @JvmField val id: Long, prev: Node?) : Cleanable {
        // This array contains the data of this segment. In order not to have
        // redundant cache misses, both values to be sent and continuations
        // are stored in the same array at indexes `2i` and `2i+1` respectively.
        private val _data = atomicArrayOfNulls<Any?>(segmentSize * 2)
        // Pointer to the next node in the waiting queue, maintained similar to
        // MS queue algorithm. This pointer can be either null, REMOVED_TAIL, `Node`, or `RemovedNode`
        // depending on the fact if it is logically removed after the cleaning algorithm part.
        private val _next = atomic<Node?>(null)
        // Counter of cleaned elements. The node should be removed from the waiting queue
        // (in case it is not a head) when the counter exceeds `segmentSize`.
        private val _cleaned = atomic(0)
        // Lazy updated link to the previous node, which is used for cleaning
        private val _prev = atomic(prev)
        val removed get() = _cleaned.value == segmentSize
        constructor(segmentSize: Int, id: Long, cont: Any, element: Any, prev: Node?)
            : this(segmentSize = segmentSize, id = id, prev = prev)
        {
            _data[1].value = cont
            _data[0].value = element
        }
        // This method helps to read a continuation
        // located by the specified index and helps other threads
        // to invoke their descriptors if needed. This method should
        // be invoked after the corresponding element has been read,
        // so it is guaranteed that the continuation has been stored.
        fun readCont(index: Int): Any {
            while (true) {
                val cont = getContVolatile(index)!! // can't be null
                if (cont === TAKEN_CONTINUATION) return TAKEN_CONTINUATION
                return cont
            }
        }
        override fun clean(index: Int) {
            // Clean the specified node item and
            // check if all node items are cleaned.
            val cont = getCont(index)
            if (cont == TAKEN_CONTINUATION) return
            if (!casCont(index, cont, TAKEN_CONTINUATION)) return
            putElement(index, TAKEN_ELEMENT)
            if (_cleaned.incrementAndGet() < segmentSize) return
            // Removing this node
            remove()
        }
        /**
         * Removes this node from the waiting queue and clean all references to it.
         */
        fun remove() {
            var next = next() ?: return // tail can't be removed
            // Find the first non-removed node (tail is always non-removed)
            while (next.removed) {
                next = next.next() ?: break
            }
            // Find the first non-removed prev and remove the node
            var prev = _prev.value
            while (true) {
                if (prev == null) {
                    next.movePrevToLeft(null)
                    return
                }
                if (prev.removed) {
                    prev = prev._prev.value
                    continue
                }
                next.movePrevToLeft(prev)
                prev.moveNextToRight(next)
                if (next.removed || !prev.removed) return
                prev = prev._prev.value
            }
        }
        private fun moveNextToRight(next: Node) {
            while (true) {
                val curNext = _next.value!!
                if (next.id <= curNext.id) return
                if (_next.compareAndSet(curNext, next)) return
            }
        }
        private fun movePrevToLeft(prev: Node?) {
            while (true) {
                val curPrev = _prev.value ?: return
                if (prev != null && curPrev.id <= prev.id) return
                if (_prev.compareAndSet(curPrev, prev)) return
            }
        }
        fun next() = _next.value
        fun casNext(old: Node?, new: Node?) = _next.compareAndSet(old, new)
        fun putPrev(node: Node?) {
            _prev.lazySet(node)
        }
        inline fun putElementVolatile(index: Int, element: Any) {
            _data[index * 2].value = element
        }
        inline fun putElement(index: Int, element: Any) {
            _data[index * 2].lazySet(element)
        }
        inline fun getElementVolatile(index: Int): Any? {
            return _data[index * 2].value
        }
        inline fun getElement(index: Int): Any? {
            return _data[index * 2].value
        }
        inline fun casElement(index: Int, expect: Any?, update: Any): Boolean {
            return _data[index * 2].compareAndSet(expect, update)
        }
        inline fun putContVolatile(index: Int, element: Any) {
            _data[index * 2 + 1].value = element
        }
        inline fun putCont(index: Int, element: Any) {
            _data[index * 2 + 1].lazySet(element)
        }
        inline fun getContVolatile(index: Int): Any? {
            return _data[index * 2 + 1].value
        }
        inline fun getCont(index: Int): Any? {
            return _data[index * 2 + 1].value
        }
        inline fun casCont(index: Int, expect: Any?, update: Any): Boolean {
            return _data[index * 2 + 1].compareAndSet(expect, update)
        }
    }
    // These head and tail nodes are managed similar to MS queue.
    // In order to determine deque and enqueue locations, `_deqIdx`
    // and `_enqIdx` should be used.
    private val _head: AtomicRef<Node>
    private val _tail: AtomicRef<Node>
    internal fun head() = _head.value
    internal fun tail() = _tail.value
    // Indexes for deque and enqueue operations on the waiting queue,
    // which indicate positions for deque and enqueue, and their
    // equality means that the waiting queue is empty. These indexes are global,
    // therefore `idx div segmentSize` specifies a node id, while `idx mod segmentSize`
    // specifies an index in the node.
    private val _deqIdx = atomic(1L)
    private val _enqIdx = atomic(1L)
    init {
        // Initialize queue with empty node similar to MS queue
        // algorithm, but this node is just empty, not sentinel.
        val emptyNode = Node(segmentSize, 0, null)
        _head = atomic(emptyNode)
        _tail = atomic(emptyNode)
    }
    public open override suspend fun send(element: E) {
        // Try to send without suspending at first,
        // invoke suspend implementation if it is not succeed.
        if (offer(element)) return
        sendOrReceiveSuspendFast<Unit>(element)
    }
    override suspend fun receive(): E {
        // Try to send without suspending at first,
        // invoke suspend implementation if it is not succeed.
        val res = poll()
        if (res != null) return res
        return sendOrReceiveSuspendFast(RECEIVER_ELEMENT)
    }
    open override fun offer(element: E): Boolean {
        return sendOrReceiveNonSuspend<Unit>(element) != null
    }

    public fun offerUnlimited(element: Any?): Boolean {
        val element = element ?: NULL
        try_again@ while (true) { // CAS loop
            var enqIdx = _enqIdx.value
            var deqIdx = _deqIdx.value
            // Retry if enqIdx is too outdated.
            if (enqIdx < deqIdx) continue@try_again
            // Check if the waiting queue is empty.
            if (deqIdx == enqIdx) {
                if (addToWaitingQueue(enqIdx, element,  UNLIMITED_CONTINUATION) != null) {
                    if (element === RECEIVER_ELEMENT) onReceiveEnqueued()
                    break@try_again
                } else continue@try_again
            } else { // Queue is not empty.
                val head = _head.value
                val headNodeId = head.id
                // Move `_deqIdx` forward if a node is missed because of cleaning procedure.
                if (deqIdx < segmentSize * headNodeId) {
                    _deqIdx.compareAndSet(deqIdx, segmentSize * headNodeId)
                    continue@try_again
                }
                // Check if `deqIdx` is not outdated.
                val deqIdxNodeId = nodeId(deqIdx, segmentSize)
                if (deqIdxNodeId < headNodeId) continue@try_again
                // Check if the head pointer should be moved forward.
                if (deqIdxNodeId > headNodeId) {
                    // `head.next()` cannot be null because we have already checked that
                    // `enqIdx` is not equals (=> greater) than `deqIdx`, what means that
                    // there is at least one more element after this node.
                    val headNext = head.next()!!
                    headNext.putPrev(null)
                    _head.compareAndSet(head, headNext)
                    continue@try_again
                }
                // Read the first element.
                val deqIdxInNode = indexInNode(deqIdx, segmentSize)
                val firstElement = readElement(head, deqIdxInNode)
                // Check that the element is not taken.
                if (firstElement === TAKEN_ELEMENT) {
                    _deqIdx.compareAndSet(deqIdx, deqIdx + 1)
                    continue@try_again
                }
                // Decide should we make a rendezvous or not. The `firstElement` is either sender or receiver.
                // Check if a rendezvous is possible and try to remove the first element in this case,
                // try to add the current continuation to the waiting queue otherwise.
                val makeRendezvous = if (element === RECEIVER_ELEMENT) firstElement !== RECEIVER_ELEMENT else firstElement === RECEIVER_ELEMENT
                if (makeRendezvous) {
                    if (tryResumeContinuation(deqIdx, head, deqIdxInNode, element)) {
                        // The rendezvous is happened, congratulations! Resume the current continuation.
                        if (element !== RECEIVER_ELEMENT) onReceiveDequeued()
                        break@try_again
                    } else continue@try_again
                } else {
                    // Store `_deqIdx` value which has been seen
                    // at the point of deciding not to make a  rendezvous.
                    val deqIdxLimit = enqIdx
                    while (true) {
                        if (addToWaitingQueue(enqIdx, element, UNLIMITED_CONTINUATION) != null) {
                            if (element === RECEIVER_ELEMENT)  onReceiveEnqueued()
                            break@try_again
                        }
                        // Re-read `_enqIdx` and `_deqIdx` and try to add the current continuation
                        // to the waiting queue if `deqIdx` is less than `_enqIdx` at the point of deciding not to make a
                        // rendezvous.
                        enqIdx = _enqIdx.value
                        deqIdx = _deqIdx.value
                        if (deqIdx >= deqIdxLimit) continue@try_again
                    }
                }
            }
        }
        return true
    }

    override fun poll(): E? {
        return sendOrReceiveNonSuspend(RECEIVER_ELEMENT)
    }

    private suspend fun <T> sendOrReceiveSuspendFast(element: Any?): T = suspendCancellableCoroutineReusable { cont ->
        val element = element ?: NULL
        try_again@ while (true) { // CAS loop
            var enqIdx = _enqIdx.value
            var deqIdx = _deqIdx.value
            // Retry if enqIdx is too outdated.
            if (enqIdx < deqIdx) continue@try_again
            // Check if the waiting queue is empty.
            if (deqIdx == enqIdx) {
                if (addToWaitingQueue(enqIdx, element, cont) != null) {
                    if (element === RECEIVER_ELEMENT) onReceiveEnqueued()
                    break@try_again
                } else continue@try_again
            } else { // Queue is not empty.
                val head = _head.value
                val headNodeId = head.id
                // Move `_deqIdx` forward if a node is missed because of cleaning procedure.
                if (deqIdx < segmentSize * headNodeId) {
                    _deqIdx.compareAndSet(deqIdx, segmentSize * headNodeId)
                    continue@try_again
                }
                // Check if `deqIdx` is not outdated.
                val deqIdxNodeId = nodeId(deqIdx, segmentSize)
                if (deqIdxNodeId < headNodeId) continue@try_again
                // Check if the head pointer should be moved forward.
                if (deqIdxNodeId > headNodeId) {
                    // `head.next()` cannot be null because we have already checked that
                    // `enqIdx` is not equals (=> greater) than `deqIdx`, what means that
                    // there is at least one more element after this node.
                    val headNext = head.next()!!
                    headNext.putPrev(null)
                    _head.compareAndSet(head, headNext)
                    continue@try_again
                }
                // Read the first element.
                val deqIdxInNode = indexInNode(deqIdx, segmentSize)
                val firstElement = readElement(head, deqIdxInNode)
                // Check that the element is not taken.
                if (firstElement === TAKEN_ELEMENT) {
                    _deqIdx.compareAndSet(deqIdx, deqIdx + 1)
                    continue@try_again
                }
                // Decide should we make a rendezvous or not. The `firstElement` is either sender or receiver.
                // Check if a rendezvous is possible and try to remove the first element in this case,
                // try to add the current continuation to the waiting queue otherwise.
                val makeRendezvous = if (element === RECEIVER_ELEMENT) firstElement !== RECEIVER_ELEMENT else firstElement === RECEIVER_ELEMENT
                if (makeRendezvous) {
                    if (tryResumeContinuation(deqIdx, head, deqIdxInNode, element)) {
                        // The rendezvous is happened, congratulations! Resume the current continuation.
                        val res = (if (element === RECEIVER_ELEMENT) firstElement else Unit) as T
                        cont.resume(res)
                        if (element !== RECEIVER_ELEMENT) onReceiveDequeued()
                        break@try_again
                    } else continue@try_again
                } else {
                    // Store `_deqIdx` value which has been seen
                    // at the point of deciding not to make a  rendezvous.
                    val deqIdxLimit = enqIdx
                    while (true) {
                        if (addToWaitingQueue(enqIdx, element, cont) != null) {
                            if (element === RECEIVER_ELEMENT)  onReceiveEnqueued()
                            break@try_again
                        }
                        // Re-read `_enqIdx` and `_deqIdx` and try to add the current continuation
                        // to the waiting queue if `deqIdx` is less than `_enqIdx` at the point of deciding not to make a
                        // rendezvous.
                        enqIdx = _enqIdx.value
                        deqIdx = _deqIdx.value
                        if (deqIdx >= deqIdxLimit) continue@try_again
                    }
                }
            }
        }
    }

    private fun <T> sendOrReceiveNonSuspend(element: Any?): T? {
        val element = element ?: NULL
        try_again@ while (true) { // CAS loop
            val enqIdx = _enqIdx.value
            val deqIdx = _deqIdx.value
            // Retry if enqIdx is too outdated.
            if (enqIdx < deqIdx) continue@try_again
            // Check if the waiting queue is empty.
            if (deqIdx == enqIdx) {
                return null
            } else { // Queue is not empty.
                val head = _head.value
                val headNodeId = head.id
                // Move `_deqIdx` forward if a node is missed because of cleaning procedure.
                if (deqIdx < segmentSize * headNodeId) {
                    _deqIdx.compareAndSet(deqIdx, segmentSize * headNodeId)
                    continue@try_again
                }
                // Check if `deqIdx` is not outdated.
                val deqIdxNodeId = nodeId(deqIdx, segmentSize)
                if (deqIdxNodeId < headNodeId) continue@try_again
                // Check if the head pointer should be moved forward.
                if (deqIdxNodeId > headNodeId) {
                    // `head.next()` cannot be null because we have already checked that
                    // `enqIdx` is not equals (=> greater) than `deqIdx`, what means that
                    // there is at least one more element after this node.
                    val headNext = head.next()!!
                    headNext.putPrev(null)
                    _head.compareAndSet(head, headNext)
                    continue@try_again
                }
                // Read the first element.
                val deqIdxInNode = indexInNode(deqIdx, segmentSize)
                val firstElement = readElement(head, deqIdxInNode)
                // Check that the element is not taken.
                if (firstElement === TAKEN_ELEMENT) {
                    _deqIdx.compareAndSet(deqIdx, deqIdx + 1)
                    continue@try_again
                }
                // Decide should we make a rendezvous or not. The `firstElement` is either sender or receiver.
                // Check if a rendezvous is possible and try to remove the first element in this case,
                // try to add the current continuation to the waiting queue otherwise.
                val makeRendezvous = if (element === RECEIVER_ELEMENT) firstElement !== RECEIVER_ELEMENT else firstElement === RECEIVER_ELEMENT
                if (makeRendezvous) {
                    if (tryResumeContinuation(deqIdx, head, deqIdxInNode, element)) {
                        // The rendezvous is happened, congratulations! Resume the first element.
                        return (if (element === RECEIVER_ELEMENT) firstElement else Unit) as T
                    } else continue@try_again
                } else return null
            }
        }
    }
    // Tries to read an element from the specified node
    // at the specified index. Returns the read element or
    // marks the slot as broken (sets `TAKEN_ELEMENT` to the slot)
    // and returns `TAKEN_ELEMENT` if the element is unavailable.
    private fun readElement(node: Node, index: Int): Any? {
        // Spin wait on the slot.
        val element = node.getElementVolatile(index)
        if (element != null) return if (element === NULL) null else element
        // Cannot spin forever, mark the slot as broken if it is still unavailable.
        return if (node.casElement(index, null, TAKEN_ELEMENT)) {
            TAKEN_ELEMENT
        } else {
            // The element is set, read it and return.
            val e = node.getElementVolatile(index)
            if (e === NULL) null else e
        }
    }
    private fun addToWaitingQueue(enqIdx: Long, element: Any, cont: Any): Node? {
        // Count enqIdx parts
        val enqIdxNodeId = nodeId(enqIdx, segmentSize)
        val enqIdxInNode = indexInNode(enqIdx, segmentSize)
        // Read tail and its id
        val tail = _tail.value
        val tailNodeId = tail.id
        // Check if enqIdx is not outdated
        if (tailNodeId > enqIdxNodeId) return null
        // Check if we should help with a new node adding
        if (tailNodeId == enqIdxNodeId && enqIdxInNode == 0) {
            _enqIdx.compareAndSet(enqIdx, enqIdx + 1)
            return null
        }
        // Check if a new node should be added, store the continuation to the current tail node otherwise.
        if (tailNodeId == enqIdxNodeId - 1 && enqIdxInNode == 0) {
            val addedNode = addNewNode(enqIdx, tail, cont, element)
            return if (addedNode != null) addedNode else null
        } else {
            return if (storeContinuation(enqIdx, tail, enqIdxInNode, cont, element)) tail
            else null
        }
    }
    // Adds a new node with the specified continuation and element to the tail. Works similar to MS queue algorithm,
    // but updates `_enqIdx` in addition to the tail pointer. Return the added node on success, `null` otherwise.
    private fun addNewNode(enqIdx: Long, tail: Node, cont: Any, element: Any): Node? {
        while (true) {
            // If next node is not null, help to move the tail pointer.
            val tailNext = tail.next()
            if (tailNext != null) {
                // If this CAS fails, another thread moved the tail pointer.
                _tail.compareAndSet(tail, tailNext)
                _enqIdx.compareAndSet(enqIdx, enqIdx + 1)
                return null
            }
            // Create a new node with this continuation and element and try to add it
            val newTail = Node(segmentSize, tail.id + 1, cont, element, tail)
            if (tail.casNext(null, newTail)) {
                // New node has been added, try to move `_tail`
                // and `_enqIdx` forward. If the CAS fails, another thread moved it.
                _tail.compareAndSet(tail, newTail)
                _enqIdx.compareAndSet(enqIdx, enqIdx + 1)
                if (tail.removed) tail.remove()
                return newTail
            } else continue
        }
    }
    // Tries to store the current continuation and the element (in this order!)
    // to the specified node at the specified index. Returns `true` on success,
    // `false` otherwise`.
    private fun storeContinuation(enqIdx: Long, node: Node, index: Int, cont: Any, element: Any): Boolean {
        // Try to move enqueue index forward, return `false` if fails.
        if (!_enqIdx.compareAndSet(enqIdx, enqIdx + 1)) return false
        // Slot `index` is claimed, try to store the continuation and the element (in this order!) to it.
        // Can fail if another thread marked this slot as broken, return `false` in this case.
        node.putCont(index, cont)
        if (node.casElement(index, null, element)) {
            // The continuation has been added successfully.
            return true
        } else {
            // The slot is broken, clean it and return `false`.
            node.putCont(index, TAKEN_CONTINUATION)
            return false
        }
    }
    // Try to remove a continuation from the specified node at the
    // specified index and resume it. Returns `true` on success, `false` otherwise.
    private fun tryResumeContinuation(deqIdx: Long, head: Node, index: Int, element: Any): Boolean {
        // Try to move 'deqIdx' forward, return `false` if fails.
        if (!_deqIdx.compareAndSet(deqIdx, deqIdx + 1)) return false
        // Read a continuation and CAS it to `TAKEN_CONTINUATION`
        var anotherCont: Any
        while (true) {
            anotherCont = head.readCont(index)
            if (anotherCont === TAKEN_CONTINUATION) return false
            if (head.casCont(index, anotherCont, TAKEN_CONTINUATION)) break
        }
        // Clear the cell.
        head.putElement(index, TAKEN_ELEMENT)
        // Try to resume the continuation.
        val contResult = if (element === RECEIVER_ELEMENT) Unit else if (element === NULL) null else element
        if (anotherCont === UNLIMITED_CONTINUATION) return true
        anotherCont as CancellableContinuation<in Any?>
        return anotherCont.tryResumeCont(contResult)
    }

    internal companion object {
        @JvmStatic inline fun nodeId(globalIdx: Long, segmentSize: Int) = globalIdx / segmentSize
        @JvmStatic inline fun indexInNode(globalIdx: Long, segmentSize: Int) = (globalIdx % segmentSize).toInt()
        @JvmField val RECEIVER_ELEMENT = Symbol("RCV")
        @JvmField val NULL = Symbol("NULL")
        @JvmField val UNLIMITED_CONTINUATION = Any()
        @JvmField val TAKEN_CONTINUATION = Any()
        @JvmField val TAKEN_ELEMENT = Any()
        @JvmField
        val REMOVED_TAIL = Any()
        @JvmStatic
        private fun <FUNC_RESULT> actOnSendAndOnReceive(result: Any?, block: (FUNC_RESULT) -> Any?): Any? {
            when {
                result === RECEIVER_ELEMENT -> return block(Unit as FUNC_RESULT)
                else -> return block(result as FUNC_RESULT)
            }
        }
    }

    @ExperimentalCoroutinesApi
    override val isClosedForSend: Boolean
        get() = TODO("Not yet implemented")
    override val onSend: SelectClause2<E, SendChannel<E>>
        get() = TODO("Not yet implemented")

    override fun trySend(element: E): ChannelResult<Unit> {
        TODO("Not yet implemented")
    }

    override fun close(cause: Throwable?): Boolean {
        TODO("Not yet implemented")
    }

    @ExperimentalCoroutinesApi
    override fun invokeOnClose(handler: (cause: Throwable?) -> Unit) {
        TODO("Not yet implemented")
    }

    @ExperimentalCoroutinesApi
    override val isClosedForReceive: Boolean
        get() = TODO("Not yet implemented")

    @ExperimentalCoroutinesApi
    override val isEmpty: Boolean
        get() = TODO("Not yet implemented")
    override val onReceive: SelectClause1<E>
        get() = TODO("Not yet implemented")

    override suspend fun receiveCatching(): ChannelResult<E> {
        TODO("Not yet implemented")
    }

    override val onReceiveCatching: SelectClause1<ChannelResult<E>>
        get() = TODO("Not yet implemented")

    override fun tryReceive(): ChannelResult<E> {
        TODO("Not yet implemented")
    }

    override fun iterator(): ChannelIterator<E> {
        TODO("Not yet implemented")
    }

    override fun cancel(cause: CancellationException?) {
        TODO("Not yet implemented")
    }

    override fun cancel(cause: Throwable?): Boolean {
        TODO("Not yet implemented")
    }
}
private const val segmentSize: Int = 32


public interface Cleanable {
    public fun clean(index: Int)
}

internal fun <T> CancellableContinuation<T>.tryResumeCont(value: T): Boolean {
    // Token is null if this continuation is cancelled
    val token = tryResume(value) ?: return false
    // This continuation can be resumed, complete and return `true`
    completeResume(token)
    return true
}