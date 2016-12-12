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

#include <unordered_set>

#include <realm/table_view.hpp>
#include <realm/column.hpp>
#include <realm/column_tpl.hpp>
#include <realm/impl/sequential_getter.hpp>
#include <realm/index_string.hpp>
#include <realm/query_conditions.hpp>
#include <realm/util/utf8.hpp>

using namespace realm;

TableViewBase::TableViewBase(TableViewBase& src, HandoverPatch& patch, MutableSourcePayload mode)
    : RowIndexes(src, mode)
    , m_linked_column(src.m_linked_column)
{
    patch.was_in_sync = src.is_in_sync();
    // m_query must be exported after patch.was_in_sync is updated
    // as exporting m_query will bring src out of sync.
    m_query = Query(src.m_query, patch.query_patch, mode);

    Table::generate_patch(src.m_table.get(), patch.m_table);
    LinkView::generate_patch(src.m_linkview_source, patch.linkview_patch);
    SortDescriptor::generate_patch(src.m_sorting_predicate, patch.sort_patch);
    SortDescriptor::generate_patch(src.m_distinct_predicate, patch.distinct_patch);
    if (src.m_linked_column) {
        ConstRow::generate_patch(src.m_linked_row, patch.linked_row);
        patch.linked_col = src.m_linked_column->get_origin_column_index();
    }

    src.m_last_seen_version = util::none; // bring source out-of-sync, now that it has lost its data
    m_last_seen_version = 0;
    m_start = src.m_start;
    m_end = src.m_end;
    m_limit = src.m_limit;
}

TableViewBase::TableViewBase(const TableViewBase& src, HandoverPatch& patch, ConstSourcePayload mode)
    : RowIndexes(src, mode)
    , m_linked_column(src.m_linked_column)
    , m_query(src.m_query, patch.query_patch, mode)
{
    if (mode == ConstSourcePayload::Stay)
        patch.was_in_sync = false;
    else
        patch.was_in_sync = src.is_in_sync();
    Table::generate_patch(src.m_table.get(), patch.m_table);
    if (src.m_linked_column) {
        ConstRow::generate_patch(src.m_linked_row, patch.linked_row);
        patch.linked_col = src.m_linked_column->get_origin_column_index();
    }
    LinkView::generate_patch(src.m_linkview_source, patch.linkview_patch);
    SortDescriptor::generate_patch(src.m_sorting_predicate, patch.sort_patch);
    SortDescriptor::generate_patch(src.m_distinct_predicate, patch.distinct_patch);

    m_last_seen_version = 0;
    m_start = src.m_start;
    m_end = src.m_end;
    m_limit = src.m_limit;
}

void TableViewBase::apply_patch(HandoverPatch& patch, Group& group)
{
    m_table = Table::create_from_and_consume_patch(patch.m_table, group);
    m_table->register_view(this);
    m_query.apply_patch(patch.query_patch, group);
    m_linkview_source = LinkView::create_from_and_consume_patch(patch.linkview_patch, group);
    m_sorting_predicate = SortDescriptor::create_from_and_consume_patch(patch.sort_patch, *m_table);
    m_distinct_predicate = SortDescriptor::create_from_and_consume_patch(patch.distinct_patch, *m_table);

    if (patch.linked_row) {
        m_linked_column = &m_table->get_column_link_base(patch.linked_col).get_backlink_column();
        m_linked_row.apply_and_consume_patch(patch.linked_row, group);
    }

    if (patch.was_in_sync)
        m_last_seen_version = outside_version();
    else
        m_last_seen_version = util::none;
}

// Searching

// find_*_integer() methods are used for all "kinds" of integer values (bool, int, OldDateTime)

size_t TableViewBase::find_first_integer(size_t column_ndx, int64_t value) const
{
    check_cookie();

    for (size_t i = 0; i < m_row_indexes.size(); i++)
        if (is_row_attached(i) && get_int(column_ndx, i) == value)
            return i;
    return size_t(-1);
}

size_t TableViewBase::find_first_float(size_t column_ndx, float value) const
{
    check_cookie();

    for (size_t i = 0; i < m_row_indexes.size(); i++)
        if (is_row_attached(i) && get_float(column_ndx, i) == value)
            return i;
    return size_t(-1);
}

size_t TableViewBase::find_first_double(size_t column_ndx, double value) const
{
    check_cookie();

    for (size_t i = 0; i < m_row_indexes.size(); i++)
        if (is_row_attached(i) && get_double(column_ndx, i) == value)
            return i;
    return size_t(-1);
}

size_t TableViewBase::find_first_string(size_t column_ndx, StringData value) const
{
    check_cookie();

    REALM_ASSERT_COLUMN_AND_TYPE(column_ndx, type_String);

    for (size_t i = 0; i < m_row_indexes.size(); i++)
        if (is_row_attached(i) && get_string(column_ndx, i) == value)
            return i;
    return size_t(-1);
}

size_t TableViewBase::find_first_binary(size_t column_ndx, BinaryData value) const
{
    check_cookie();

    REALM_ASSERT_COLUMN_AND_TYPE(column_ndx, type_Binary);

    for (size_t i = 0; i < m_row_indexes.size(); i++)
        if (is_row_attached(i) && get_binary(column_ndx, i) == value)
            return i;
    return size_t(-1);
}


// Aggregates ----------------------------------------------------

// count_target is ignored by all <int function> except Count. Hack because of bug in optional
// arguments in clang and vs2010 (fixed in 2012)
template <int function, typename T, typename R, class ColType>
R TableViewBase::aggregate(R (ColType::*aggregateMethod)(size_t, size_t, size_t, size_t*) const, size_t column_ndx,
                           T count_target, size_t* return_ndx) const
{
    check_cookie();

    using ColTypeTraits = ColumnTypeTraits<typename ColType::value_type>;
    REALM_ASSERT_COLUMN_AND_TYPE(column_ndx, ColTypeTraits::id);
    REALM_ASSERT(function == act_Sum || function == act_Max || function == act_Min || function == act_Count ||
                 function == act_Average);
    REALM_ASSERT(m_table);
    REALM_ASSERT(column_ndx < m_table->get_column_count());
    if ((m_row_indexes.size() - m_num_detached_refs) == 0) {
        if (return_ndx) {
            if (function == act_Average)
                *return_ndx = 0;
            else
                *return_ndx = npos;
        }
        return 0;
    }

    typedef typename ColTypeTraits::leaf_type ArrType;
    const ColType* column = static_cast<ColType*>(&m_table->get_column_base(column_ndx));

    if (m_num_detached_refs == 0 && m_row_indexes.size() == column->size()) {
        // direct aggregate on the column
        if (function == act_Count)
            return static_cast<R>(column->count(count_target));
        else
            return (column->*aggregateMethod)(0, size_t(-1), size_t(-1), return_ndx); // end == limit == -1
    }

    // Array object instantiation must NOT allocate initial memory (capacity)
    // with 'new' because it will lead to mem leak. The column keeps ownership
    // of the payload in array and will free it itself later, so we must not call destroy() on array.
    ArrType arr(column->get_alloc());
    const ArrType* arrp = nullptr;
    size_t leaf_start = 0;
    size_t leaf_end = 0;
    size_t row_ndx;

    R res = R{};
    auto first = column->get(to_size_t(m_row_indexes.get(0)));

    if (return_ndx)
        *return_ndx = 0;

    if (function == act_Count)
        res = static_cast<R>((first == count_target ? 1 : 0));
    else {
        // FIXME: This assumes that all non-count aggregates on nullable integer columns run with
        // the NotNull condition.
        res = static_cast<R>(util::unwrap(first));
    }

    for (size_t ss = 1; ss < m_row_indexes.size(); ++ss) {

        int64_t signed_row_ndx = m_row_indexes.get(ss);

        // skip detached references:
        if (signed_row_ndx == detached_ref)
            continue;

        row_ndx = to_size_t(signed_row_ndx);

        if (row_ndx < leaf_start || row_ndx >= leaf_end) {
            size_t ndx_in_leaf;
            typename ColType::LeafInfo leaf{&arrp, &arr};
            column->get_leaf(row_ndx, ndx_in_leaf, leaf);
            leaf_start = row_ndx - ndx_in_leaf;
            leaf_end = leaf_start + arrp->size();
        }

        auto v = arrp->get(row_ndx - leaf_start);

        if (function == act_Count && v == count_target) {
            res++;
        }
        else {
            // FIXME: This assumes that all non-count aggregates on nullable integer columns run with
            // the NotNull condition.
            R unpacked = static_cast<R>(util::unwrap(v));
            if (function == act_Sum || function == act_Average) {
                res += unpacked;
            }
            else if (function == act_Max && unpacked > res) {
                res = unpacked;
                if (return_ndx)
                    *return_ndx = ss;
            }
            else if (function == act_Min && unpacked < res) {
                res = unpacked;
                if (return_ndx)
                    *return_ndx = ss;
            }
        }
    }

    if (function == act_Average)
        return res / (m_row_indexes.size() == 0 ? 1 : m_row_indexes.size());
    else
        return res;
}

// Min, Max and Count on Timestamp cannot utilize existing aggregate() methods, becuase these assume we have leaf
// types
// and also assume numeric types that support arithmetic (+, /, etc).
template <class C>
Timestamp TableViewBase::minmax_timestamp(size_t column_ndx, size_t* return_ndx) const
{
    C compare = C();
    Timestamp best = Timestamp{};
    size_t ndx = npos;
    for (size_t t = 0; t < size(); t++) {
        Timestamp ts = get_timestamp(column_ndx, t);
        // Because realm::Greater(non-null, null) == false, we need to pick the initial 'best' manually when we see
        // the first non-null entry
        if ((ndx == npos && !ts.is_null()) || compare(ts, best, ts.is_null(), best.is_null())) {
            best = ts;
            ndx = t;
        }
    }

    if (return_ndx)
        *return_ndx = ndx;

    return best;
}

// sum
int64_t TableViewBase::sum_int(size_t column_ndx) const
{
    if (m_table->is_nullable(column_ndx))
        return aggregate<act_Sum, int64_t>(&IntNullColumn::sum, column_ndx, 0);
    else
        return aggregate<act_Sum, int64_t>(&IntegerColumn::sum, column_ndx, 0);
}
double TableViewBase::sum_float(size_t column_ndx) const
{
    return aggregate<act_Sum, float>(&FloatColumn::sum, column_ndx, 0.0);
}
double TableViewBase::sum_double(size_t column_ndx) const
{
    return aggregate<act_Sum, double>(&DoubleColumn::sum, column_ndx, 0.0);
}

// Maximum
int64_t TableViewBase::maximum_int(size_t column_ndx, size_t* return_ndx) const
{
    if (m_table->is_nullable(column_ndx))
        return aggregate<act_Max, int64_t>(&IntNullColumn::maximum, column_ndx, 0, return_ndx);
    else
        return aggregate<act_Max, int64_t>(&IntegerColumn::maximum, column_ndx, 0, return_ndx);
}
float TableViewBase::maximum_float(size_t column_ndx, size_t* return_ndx) const
{
    return aggregate<act_Max, float>(&FloatColumn::maximum, column_ndx, 0.0, return_ndx);
}
double TableViewBase::maximum_double(size_t column_ndx, size_t* return_ndx) const
{
    return aggregate<act_Max, double>(&DoubleColumn::maximum, column_ndx, 0.0, return_ndx);
}
OldDateTime TableViewBase::maximum_olddatetime(size_t column_ndx, size_t* return_ndx) const
{
    if (m_table->is_nullable(column_ndx))
        return aggregate<act_Max, int64_t>(&IntNullColumn::maximum, column_ndx, 0, return_ndx);
    else
        return aggregate<act_Max, int64_t>(&IntegerColumn::maximum, column_ndx, 0, return_ndx);
}

Timestamp TableViewBase::maximum_timestamp(size_t column_ndx, size_t* return_ndx) const
{
    return minmax_timestamp<realm::Greater>(column_ndx, return_ndx);
}


// Minimum
int64_t TableViewBase::minimum_int(size_t column_ndx, size_t* return_ndx) const
{
    if (m_table->is_nullable(column_ndx))
        return aggregate<act_Min, int64_t>(&IntNullColumn::minimum, column_ndx, 0, return_ndx);
    else
        return aggregate<act_Min, int64_t>(&IntegerColumn::minimum, column_ndx, 0, return_ndx);
}
float TableViewBase::minimum_float(size_t column_ndx, size_t* return_ndx) const
{
    return aggregate<act_Min, float>(&FloatColumn::minimum, column_ndx, 0.0, return_ndx);
}
double TableViewBase::minimum_double(size_t column_ndx, size_t* return_ndx) const
{
    return aggregate<act_Min, double>(&DoubleColumn::minimum, column_ndx, 0.0, return_ndx);
}
OldDateTime TableViewBase::minimum_olddatetime(size_t column_ndx, size_t* return_ndx) const
{
    if (m_table->is_nullable(column_ndx))
        return aggregate<act_Max, int64_t>(&IntNullColumn::minimum, column_ndx, 0, return_ndx);
    else
        return aggregate<act_Max, int64_t>(&IntegerColumn::minimum, column_ndx, 0, return_ndx);
}

Timestamp TableViewBase::minimum_timestamp(size_t column_ndx, size_t* return_ndx) const
{
    return minmax_timestamp<realm::Less>(column_ndx, return_ndx);
}

// Average. The number of values used to compute the result is written to `value_count` by callee
double TableViewBase::average_int(size_t column_ndx, size_t* value_count) const
{
    if (m_table->is_nullable(column_ndx))
        return aggregate<act_Average, int64_t>(&IntNullColumn::average, column_ndx, 0, value_count);
    else
        return aggregate<act_Average, int64_t>(&IntegerColumn::average, column_ndx, 0, value_count);
}
double TableViewBase::average_float(size_t column_ndx, size_t* value_count) const
{
    return aggregate<act_Average, float>(&FloatColumn::average, column_ndx, 0, value_count);
}
double TableViewBase::average_double(size_t column_ndx, size_t* value_count) const
{
    return aggregate<act_Average, double>(&DoubleColumn::average, column_ndx, 0, value_count);
}

// Count
size_t TableViewBase::count_int(size_t column_ndx, int64_t target) const
{
    if (m_table->is_nullable(column_ndx))
        return aggregate<act_Count, int64_t, size_t, IntNullColumn>(nullptr, column_ndx, target);
    else
        return aggregate<act_Count, int64_t, size_t, IntegerColumn>(nullptr, column_ndx, target);
}
size_t TableViewBase::count_float(size_t column_ndx, float target) const
{
    return aggregate<act_Count, float, size_t, FloatColumn>(nullptr, column_ndx, target);
}
size_t TableViewBase::count_double(size_t column_ndx, double target) const
{
    return aggregate<act_Count, double, size_t, DoubleColumn>(nullptr, column_ndx, target);
}

size_t TableViewBase::count_timestamp(size_t column_ndx, Timestamp target) const
{
    size_t count = 0;
    for (size_t t = 0; t < size(); t++) {
        Timestamp ts = get_timestamp(column_ndx, t);
        realm::Equal e;
        if (e(ts, target, ts.is_null(), target.is_null())) {
            count++;
        }
    }
    return count;
}

// Simple pivot aggregate method. Experimental! Please do not document method publicly.
void TableViewBase::aggregate(size_t group_by_column, size_t aggr_column, Table::AggrType op, Table& result) const
{
    m_table->aggregate(group_by_column, aggr_column, op, result, &m_row_indexes);
}

void TableViewBase::to_json(std::ostream& out) const
{
    check_cookie();

    // Represent table as list of objects
    out << "[";

    const size_t row_count = size();
    for (size_t r = 0; r < row_count; ++r) {
        const int64_t real_row_index = get_source_ndx(r);
        if (real_row_index != detached_ref) {
            if (r > 0)
                out << ",";
            m_table->to_json_row(to_size_t(real_row_index), out);
        }
    }

    out << "]";
}

void TableViewBase::to_string(std::ostream& out, size_t limit) const
{
    check_cookie();

    // Print header (will also calculate widths)
    std::vector<size_t> widths;
    m_table->to_string_header(out, widths);

    // Set limit=-1 to print all rows, otherwise only print to limit
    const size_t row_count = num_attached_rows();
    const size_t out_count = (limit == size_t(-1)) ? row_count : (row_count < limit) ? row_count : limit;

    // Print rows
    size_t i = 0;
    size_t count = out_count;
    while (count) {
        const int64_t real_row_index = get_source_ndx(i);
        if (real_row_index != detached_ref) {
            m_table->to_string_row(to_size_t(real_row_index), out, widths);
            --count;
        }
        ++i;
    }

    if (out_count < row_count) {
        const size_t rest = row_count - out_count;
        out << "... and " << rest << " more rows (total " << row_count << ")";
    }
}

void TableViewBase::row_to_string(size_t row_ndx, std::ostream& out) const
{
    check_cookie();

    REALM_ASSERT(row_ndx < m_row_indexes.size());

    // Print header (will also calculate widths)
    std::vector<size_t> widths;
    m_table->to_string_header(out, widths);

    // Print row contents
    int64_t real_ndx = get_source_ndx(row_ndx);
    REALM_ASSERT(real_ndx != detached_ref);
    m_table->to_string_row(to_size_t(real_ndx), out, widths);
}


bool TableViewBase::depends_on_deleted_object() const
{
    uint64_t max = std::numeric_limits<uint64_t>::max();
    // outside_version() will call itself recursively for each TableView in the dependency chain
    // and terminate with `max` if the deepest depends on a deleted LinkList or Row
    return outside_version() == max;
}

// Return version of whatever this TableView depends on
uint64_t TableViewBase::outside_version() const
{
    check_cookie();

    // If the TableView directly or indirectly depends on a LinkList that has been deleted, then its m_table has been
    // set to 0 and there is no way to know its version number. So return biggest possible value to trigger a refresh
    // later
    uint64_t max = std::numeric_limits<uint64_t>::max();

    LinkView* lvp = dynamic_cast<LinkView*>(m_query.m_view);
    if (lvp) {
        // This LinkView depends on Query that is restricted by LinkList (with where(&linklist))
        if (lvp->is_attached()) {
            return lvp->get_origin_table().m_version;
        }
        else {
            // LinkList was deleted
            return max;
        }
    }

    TableView* tvp = dynamic_cast<TableView*>(m_query.m_view);
    if (tvp) {
        // This LinkView depends on a Query that is restricted by a LinkView (with where(&linkview))
        return tvp->outside_version();
    }

    if (m_linkview_source) {
        // m_linkview_source is set if-and-only-if this TableView was created by LinkView::get_as_sorted_view().
        if (m_linkview_source->is_attached()) {
            return m_linkview_source->get_origin_table().m_version;
        }
        else {
            return max;
        }
    }

    if (m_linked_column && !m_linked_row) {
        // m_linked_column is set when created by Table::get_backlink_view.
        return max;
    }

    // This TableView was created by a method directly on Table, such as Table::find_all(int64_t)
    return m_table->m_version;
}

bool TableViewBase::is_in_sync() const
{
    check_cookie();

    bool table = bool(m_table);
    bool version = bool(m_last_seen_version == outside_version());
    bool view = bool(m_query.m_view);

    return table && version && (view ? m_query.m_view->is_in_sync() : true);
}

uint_fast64_t TableViewBase::sync_if_needed() const
{
    if (!is_in_sync()) {
        // FIXME: Is this a reasonable handling of constness?
        const_cast<TableViewBase*>(this)->do_sync();
    }
    return *m_last_seen_version;
}


void TableViewBase::adj_row_acc_insert_rows(size_t row_ndx, size_t num_rows) noexcept
{
    m_row_indexes.adjust_ge(int_fast64_t(row_ndx), num_rows);
}


void TableViewBase::adj_row_acc_erase_row(size_t row_ndx) noexcept
{
    size_t it = 0;
    for (;;) {
        it = m_row_indexes.find_first(row_ndx, it);
        if (it == not_found)
            break;
        ++m_num_detached_refs;
        m_row_indexes.set(it, -1);
    }
    m_row_indexes.adjust_ge(int_fast64_t(row_ndx) + 1, -1);
}


void TableViewBase::adj_row_acc_move_over(size_t from_row_ndx, size_t to_row_ndx) noexcept
{
    size_t it = 0;
    // kill any refs to the target row ndx
    for (;;) {
        it = m_row_indexes.find_first(to_row_ndx, it);
        if (it == not_found)
            break;
        ++m_num_detached_refs;
        m_row_indexes.set(it, -1);
    }
    // adjust any refs to the source row ndx to point to the target row ndx.
    it = 0;
    for (;;) {
        it = m_row_indexes.find_first(from_row_ndx, it);
        if (it == not_found)
            break;
        m_row_indexes.set(it, to_row_ndx);
    }
}


void TableViewBase::adj_row_acc_clear() noexcept
{
    m_num_detached_refs = m_row_indexes.size();
    for (size_t i = 0, num_rows = m_row_indexes.size(); i < num_rows; ++i)
        m_row_indexes.set(i, -1);
}


void TableView::remove(size_t row_ndx, RemoveMode underlying_mode)
{
    check_cookie();

    REALM_ASSERT(m_table);
    REALM_ASSERT(row_ndx < m_row_indexes.size());

    bool sync_to_keep = m_last_seen_version == outside_version();

    size_t origin_row_ndx = size_t(m_row_indexes.get(row_ndx));

    // Update refs
    m_row_indexes.erase(row_ndx);

    // Delete row in origin table
    using tf = _impl::TableFriend;
    bool is_move_last_over = (underlying_mode == RemoveMode::unordered);
    tf::erase_row(*m_table, origin_row_ndx, is_move_last_over); // Throws

    // It is important to not accidentally bring us in sync, if we were
    // not in sync to start with:
    if (sync_to_keep)
        m_last_seen_version = outside_version();

    // Adjustment of row indexes greater than the removed index is done by
    // adj_row_acc_move_over or adj_row_acc_erase_row as sideeffect of the actual
    // update of the table, so we don't need to do it here (it has already been done)
}


void TableView::clear(RemoveMode underlying_mode)
{
    REALM_ASSERT(m_table);

    bool sync_to_keep = m_last_seen_version == outside_version();

    // Temporarily unregister this view so that it's not pointlessly updated
    // for the row removals
    using tf = _impl::TableFriend;
    tf::unregister_view(*m_table, this);

    bool is_move_last_over = (underlying_mode == RemoveMode::unordered);
    tf::batch_erase_rows(*m_table, m_row_indexes, is_move_last_over); // Throws

    m_row_indexes.clear();
    m_num_detached_refs = 0;
    tf::register_view(*m_table, this); // Throws

    // It is important to not accidentally bring us in sync, if we were
    // not in sync to start with:
    if (sync_to_keep)
        m_last_seen_version = outside_version();
}

void TableViewBase::sync_distinct_view(size_t column)
{
    m_row_indexes.clear();
    m_num_detached_refs = 0;
    m_distinct_column_source = column;
    if (m_distinct_column_source != npos) {
        REALM_ASSERT(m_table);
        REALM_ASSERT(m_table->has_search_index(m_distinct_column_source));
        if (!m_table->is_degenerate()) {
            const ColumnBase& col = m_table->get_column_base(m_distinct_column_source);
            col.get_search_index()->distinct(m_row_indexes);
        }
    }
}

void TableViewBase::distinct(size_t column)
{
    distinct(SortDescriptor(*m_table, {{column}}));
}

/// Remove rows that are duplicated with respect to the column set passed as argument.
/// Will keep original sorting order so that you can both have a distinct and sorted view.
void TableViewBase::distinct(SortDescriptor columns)
{
    m_distinct_predicate = std::move(columns);
    do_sync();
}


// Sort according to one column
void TableViewBase::sort(size_t column, bool ascending)
{
    sort(SortDescriptor(*m_table, {{column}}, {ascending}));
}

// Sort according to multiple columns, user specified order on each column
void TableViewBase::sort(SortDescriptor order)
{
    m_sorting_predicate = std::move(order);
    do_sort(m_sorting_predicate, m_distinct_predicate);
}

void TableViewBase::do_sync()
{
    // A TableView can be "born" from 4 different sources: LinkView, Table::get_distinct_view(),
    // Table::find_all() or Query. Here we sync with the respective source.

    if (m_linkview_source) {
        m_row_indexes.clear();
        for (size_t t = 0; t < m_linkview_source->size(); t++)
            m_row_indexes.add(m_linkview_source->get(t).get_index());
    }
    else if (m_table && m_distinct_column_source != npos) {
        sync_distinct_view(m_distinct_column_source);
    }
    else if (m_table && m_linked_column) {
        m_row_indexes.clear();
        if (m_linked_row.is_attached()) {
            size_t linked_row_ndx = m_linked_row.get_index();
            size_t backlink_count = m_linked_column->get_backlink_count(linked_row_ndx);
            for (size_t i = 0; i < backlink_count; i++)
                m_row_indexes.add(m_linked_column->get_backlink(linked_row_ndx, i));
        }
    }
    // precondition: m_table is attached
    else if (!m_query.m_table) {
        // This case gets invoked if the TableView origined from Table::find_all(T value). It is temporarely disabled
        // because it doesn't take the search parameter in count. FIXME/Todo
        REALM_ASSERT(false);
        // no valid query
        m_row_indexes.clear();
        for (size_t i = 0; i < m_table->size(); i++)
            m_row_indexes.add(i);
    }
    else {
        // valid query, so clear earlier results and reexecute it.
        if (m_row_indexes.is_attached())
            m_row_indexes.clear();
        else
            m_row_indexes.init_from_ref(Allocator::get_default(), IntegerColumn::create(Allocator::get_default()));
        // if m_query had a TableView filter, then sync it. If it had a LinkView filter, no sync is needed
        if (m_query.m_view)
            m_query.m_view->sync_if_needed();

        // find_all needs to call size() on the tableview. But if we're
        // out of sync, size() will then call do_sync and we'll have an infinite regress
        // SO: fake that we're up to date BEFORE calling find_all.
        m_query.find_all(*(const_cast<TableViewBase*>(this)), m_start, m_end, m_limit);
    }
    m_num_detached_refs = 0;

    do_sort(m_sorting_predicate, m_distinct_predicate);

    m_last_seen_version = outside_version();
}

bool TableViewBase::is_in_table_order() const
{
    if (!m_table) {
        return false;
    }
    else if (m_linkview_source) {
        return false;
    }
    else if (m_table && m_linked_column) {
        return false;
    }
    else if (!m_query.m_table) {
        // TableView originated from Table::find_all().
        return !m_sorting_predicate;
    }
    else if (m_query.produces_results_in_table_order()) {
        return !m_sorting_predicate;
    }
    else {
        return false;
    }
}
