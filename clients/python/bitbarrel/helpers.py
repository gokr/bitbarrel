"""Convenience helpers for BitBarrel Python client."""

from typing import Tuple, List, Iterator, Optional, Callable


def paginate_range_result(
    fetch_func: Callable[[str], "RangeResult"],
    start_cursor: str = "",
    callback: Optional[Callable[[str, str], None]] = None
) -> List[Tuple[str, str]]:
    """Paginate through a range query result automatically.

    Args:
        fetch_func: Function to fetch next page, takes cursor as argument
        start_cursor: Initial cursor (empty for first page)
        callback: Optional callback function called for each item

    Returns:
        List of all key-value pairs from all pages
    """
    from .client import RangeResult

    all_items = []
    cursor = start_cursor

    while True:
        result = fetch_func(cursor)

        for key, value in result.items:
            if callback:
                callback(key, value)
            all_items.append((key, value))

        if not result.hasMore or not result.nextCursor:
            break

        cursor = result.nextCursor

    return all_items


def iterate_range(
    client,
    start_key: str = "",
    end_key: str = "",
    prefix: str = "",
    page_size: int = 1000
) -> Iterator[Tuple[str, str]]:
    """Iterate over keys/values in a range or prefix.

    Args:
        client: BitBarrelClient instance
        start_key: Start key for range query
        end_key: End key for range query
        prefix: Prefix for prefix query
        page_size: Number of items per page

    Yields:
        Key-value tuples
    """
    cursor = ""

    while True:
        if prefix:
            result = client.prefix_query(prefix, page_size, cursor)
        else:
            result = client.range_query(start_key, end_key, page_size, cursor)

        if not result.items:
            break

        for key, value in result.items:
            yield key, value

        if not result.hasMore:
            break

        cursor = result.nextCursor


def get_all_with_prefix(client, prefix: str) -> List[Tuple[str, str]]:
    """Get all key-value pairs with the given prefix.

    Args:
        client: BitBarrelClient instance
        prefix: Key prefix to match

    Returns:
        List of (key, value) tuples
    """
    result = client.prefix_query(prefix)
    return list(result.items)


def get_all_in_range(
    client,
    start_key: str,
    end_key: str
) -> List[Tuple[str, str]]:
    """Get all key-value pairs in the given range.

    Args:
        client: BitBarrelClient instance
        start_key: Start of range (inclusive)
        end_key: End of range (exclusive)

    Returns:
        List of (key, value) tuples
    """
    result = client.range_query(start_key, end_key)
    return list(result.items)


def batch_set(client, items: List[Tuple[str, str]]) -> int:
    """Set multiple key-value pairs.

    Args:
        client: BitBarrelClient instance
        items: List of (key, value) tuples

    Returns:
        Number of successfully set items
    """
    success = 0
    for key, value in items:
        try:
            client.set(key, value)
            success += 1
        except Exception:
            pass
    return success


def batch_get(client, keys: List[str]) -> List[Tuple[str, Optional[str]]]:
    """Get multiple values by keys.

    Args:
        client: BitBarrelClient instance
        keys: List of keys to fetch

    Returns:
        List of (key, value or None) tuples
    """
    results = []
    for key in keys:
        try:
            value = client.get(key)
            results.append((key, value))
        except Exception:
            results.append((key, None))
    return results


def batch_delete(client, keys: List[str]) -> int:
    """Delete multiple keys.

    Args:
        client: BitBarrelClient instance
        keys: List of keys to delete

    Returns:
        Number of successfully deleted keys
    """
    success = 0
    for key in keys:
        try:
            client.delete(key)
            success += 1
        except Exception:
            pass
    return success
