/*************************************************************************
 *
 * Copyright 2016 Realm Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 **************************************************************************/

#include <utility> // pair

#include <realm/array_binary.hpp>
#include <realm/array_blob.hpp>
#include <realm/array_integer.hpp>
#include <realm/impl/destroy_guard.hpp>

using namespace realm;

void ArrayBinary::init_from_mem(MemRef mem) noexcept
{
    Array::init_from_mem(mem);
    ref_type offsets_ref = get_as_ref(0);
    ref_type blob_ref = get_as_ref(1);

    m_offsets.init_from_ref(offsets_ref);
    m_blob.init_from_ref(blob_ref);

    if (!legacy_array_type()) {
        ref_type nulls_ref = get_as_ref(2);
        m_nulls.init_from_ref(nulls_ref);
    }
}

size_t ArrayBinary::read(size_t ndx, size_t pos, char* buffer, size_t max_size) const noexcept
{
    REALM_ASSERT_3(ndx, <, m_offsets.size());

    if (!legacy_array_type() && m_nulls.get(ndx)) {
        return 0;
    }
    else {
        size_t begin_idx = ndx ? to_size_t(m_offsets.get(ndx - 1)) : 0;
        size_t end_idx = to_size_t(m_offsets.get(ndx));
        size_t sz = end_idx - begin_idx;

        size_t size_to_copy = (pos > sz) ? 0 : std::min(max_size, sz - pos);
        const char* begin = m_blob.get(begin_idx) + pos;
        const char* end = m_blob.get(begin_idx) + pos + size_to_copy;
        std::copy(begin, end, buffer);
        return size_to_copy;
    }
}

void ArrayBinary::add(BinaryData value, bool add_zero_term)
{
    REALM_ASSERT_7(value.size(), ==, 0, ||, value.data(), !=, 0);

    if (value.is_null() && legacy_array_type())
        throw LogicError(LogicError::column_not_nullable);

    m_blob.add(value.data(), value.size(), add_zero_term);
    size_t stored_size = value.size();
    if (add_zero_term)
        ++stored_size;
    size_t offset = stored_size;
    if (!m_offsets.is_empty())
        offset += to_size_t(m_offsets.back());
    m_offsets.add(offset);

    if (!legacy_array_type())
        m_nulls.add(value.is_null());
}

void ArrayBinary::set(size_t ndx, BinaryData value, bool add_zero_term)
{
    REALM_ASSERT_3(ndx, <, m_offsets.size());
    REALM_ASSERT_3(value.size(), == 0 ||, value.data());

    if (value.is_null() && legacy_array_type())
        throw LogicError(LogicError::column_not_nullable);

    int_fast64_t start = ndx ? m_offsets.get(ndx - 1) : 0;
    int_fast64_t current_end = m_offsets.get(ndx);
    size_t stored_size = value.size();
    if (add_zero_term)
        ++stored_size;
    int_fast64_t diff = (start + stored_size) - current_end;
    m_blob.replace(to_size_t(start), to_size_t(current_end), value.data(), value.size(), add_zero_term);
    m_offsets.adjust(ndx, m_offsets.size(), diff);

    if (!legacy_array_type())
        m_nulls.set(ndx, value.is_null());
}

void ArrayBinary::insert(size_t ndx, BinaryData value, bool add_zero_term)
{
    REALM_ASSERT_3(ndx, <=, m_offsets.size());
    REALM_ASSERT_3(value.size(), == 0 ||, value.data());

    if (value.is_null() && legacy_array_type())
        throw LogicError(LogicError::column_not_nullable);

    size_t pos = ndx ? to_size_t(m_offsets.get(ndx - 1)) : 0;
    m_blob.insert(pos, value.data(), value.size(), add_zero_term);

    size_t stored_size = value.size();
    if (add_zero_term)
        ++stored_size;
    m_offsets.insert(ndx, pos + stored_size);
    m_offsets.adjust(ndx + 1, m_offsets.size(), stored_size);

    if (!legacy_array_type())
        m_nulls.insert(ndx, value.is_null());
}

void ArrayBinary::erase(size_t ndx)
{
    REALM_ASSERT_3(ndx, <, m_offsets.size());

    size_t start = ndx ? to_size_t(m_offsets.get(ndx - 1)) : 0;
    size_t end = to_size_t(m_offsets.get(ndx));

    m_blob.erase(start, end);
    m_offsets.erase(ndx);
    m_offsets.adjust(ndx, m_offsets.size(), int64_t(start) - end);

    if (!legacy_array_type())
        m_nulls.erase(ndx);
}

BinaryData ArrayBinary::get(const char* header, size_t ndx, Allocator& alloc) noexcept
{
    // Column *may* be nullable if top has 3 refs (3'rd being m_nulls). Else, if it has 2, it's non-nullable
    // See comment in legacy_array_type() and also in array_binary.hpp.
    size_t siz = Array::get_size_from_header(header);
    REALM_ASSERT_7(siz, ==, 2, ||, siz, ==, 3);

    if (siz == 3) {
        std::pair<int64_t, int64_t> p = get_two(header, 1);
        const char* nulls_header = alloc.translate(to_ref(p.second));
        int64_t n = ArrayInteger::get(nulls_header, ndx);
        // 0 or 1 is all that is ever written to m_nulls; any other content would be a bug
        REALM_ASSERT_3(n == 1, ||, n == 0);
        bool null = (n != 0);
        if (null)
            return BinaryData{};
    }

    std::pair<int64_t, int64_t> p = get_two(header, 0);
    const char* offsets_header = alloc.translate(to_ref(p.first));
    const char* blob_header = alloc.translate(to_ref(p.second));
    size_t begin, end;
    if (ndx) {
        p = get_two(offsets_header, ndx - 1);
        begin = to_size_t(p.first);
        end = to_size_t(p.second);
    }
    else {
        begin = 0;
        end = to_size_t(Array::get(offsets_header, ndx));
    }
    BinaryData bd = BinaryData(ArrayBlob::get(blob_header, begin), end - begin);
    return bd;
}

// FIXME: Not exception safe (leaks are possible).
ref_type ArrayBinary::bptree_leaf_insert(size_t ndx, BinaryData value, bool add_zero_term, TreeInsertBase& state)
{
    size_t leaf_size = size();
    REALM_ASSERT_3(leaf_size, <=, REALM_MAX_BPNODE_SIZE);
    if (leaf_size < ndx)
        ndx = leaf_size;
    if (REALM_LIKELY(leaf_size < REALM_MAX_BPNODE_SIZE)) {
        insert(ndx, value, add_zero_term); // Throws
        return 0;                          // Leaf was not split
    }

    // Split leaf node
    ArrayBinary new_leaf(get_alloc());
    new_leaf.create(); // Throws
    if (ndx == leaf_size) {
        new_leaf.add(value, add_zero_term); // Throws
        state.m_split_offset = ndx;
    }
    else {
        for (size_t i = ndx; i != leaf_size; ++i)
            new_leaf.add(get(i));  // Throws
        truncate(ndx);             // Throws
        add(value, add_zero_term); // Throws
        state.m_split_offset = ndx + 1;
    }
    state.m_split_size = leaf_size + 1;
    return new_leaf.get_ref();
}


MemRef ArrayBinary::create_array(size_t size, Allocator& alloc, BinaryData values)
{
    // Only null and zero-length non-null allowed as initialization value
    REALM_ASSERT(values.size() == 0);
    Array top(alloc);
    _impl::DeepArrayDestroyGuard dg(&top);
    top.create(type_HasRefs); // Throws

    _impl::DeepArrayRefDestroyGuard dg_2(alloc);
    {
        bool context_flag = false;
        int64_t value = 0;
        MemRef mem = ArrayInteger::create_array(type_Normal, context_flag, size, value, alloc); // Throws
        dg_2.reset(mem.get_ref());
        int64_t v = from_ref(mem.get_ref());
        top.add(v); // Throws
        dg_2.release();
    }
    {
        size_t blobs_size = 0;
        MemRef mem = ArrayBlob::create_array(blobs_size, alloc); // Throws
        dg_2.reset(mem.get_ref());
        int64_t v = from_ref(mem.get_ref());
        top.add(v); // Throws
        dg_2.release();
    }
    {
        // Always create a m_nulls array, regardless if its column is marked as nullable or not. NOTE: This is new
        // - existing binary arrays from earier versions of core will not have this third array. All methods on
        // ArrayBinary must thus check if this array exists before trying to access it. If it doesn't, it must be
        // interpreted as if its column isn't nullable.
        bool context_flag = false;
        int64_t value = values.is_null() ? 1 : 0;
        MemRef mem = ArrayInteger::create_array(type_Normal, context_flag, size, value, alloc); // Throws
        dg_2.reset(mem.get_ref());
        int64_t v = from_ref(mem.get_ref());
        top.add(v); // Throws
        dg_2.release();
    }

    dg.release();
    return top.get_mem();
}


MemRef ArrayBinary::slice(size_t offset, size_t slice_size, Allocator& target_alloc) const
{
    REALM_ASSERT(is_attached());

    ArrayBinary array_slice(target_alloc);
    _impl::ShallowArrayDestroyGuard dg(&array_slice);
    array_slice.create(); // Throws
    size_t begin = offset;
    size_t end = offset + slice_size;
    for (size_t i = begin; i != end; ++i) {
        BinaryData value = get(i);
        array_slice.add(value); // Throws
    }
    dg.release();
    return array_slice.get_mem();
}


#ifdef REALM_DEBUG // LCOV_EXCL_START ignore debug functions

void ArrayBinary::to_dot(std::ostream& out, bool, StringData title) const
{
    ref_type ref = get_ref();

    out << "subgraph cluster_binary" << ref << " {" << std::endl;
    out << " label = \"ArrayBinary";
    if (title.size() != 0)
        out << "\\n'" << title << "'";
    out << "\";" << std::endl;

    Array::to_dot(out, "binary_top");
    m_offsets.to_dot(out, "offsets");
    m_blob.to_dot(out, "blob");

    out << "}" << std::endl;
}

#endif // LCOV_EXCL_STOP ignore debug functions
