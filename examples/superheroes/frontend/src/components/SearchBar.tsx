import { Component, createSignal } from 'solid-js';

interface SearchBarProps {
  onSearch: (query: string) => void;
  allPublishers: string[];
  onFilterPublisher: (publisher: string | null) => void;
}

export const SearchBar: Component<SearchBarProps> = (props) => {
  const [query, setQuery] = createSignal('');
  const [publisherFilter, setPublisherFilter] = createSignal<string>('');

  const handleSearch = () => {
    props.onSearch(query());
  };

  const handlePublisherChange = (value: string) => {
    setPublisherFilter(value);
    props.onFilterPublisher(value === '' ? null : value);
  };

  const resetFilters = () => {
    setQuery('');
    setPublisherFilter('');
    props.onSearch('');
    props.onFilterPublisher(null);
  };

  return (
    <div class="search-bar">
      <div class="search-input-group">
        <input
          type="text"
          placeholder="Search heroes by name..."
          value={query()}
          onInput={(e) => setQuery(e.currentTarget.value)}
          onKeyPress={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              handleSearch();
            }
          }}
        />
        <button class="btn btn-primary" type="button" onClick={handleSearch}>
          Search
        </button>
        <button
          class="btn"
          type="button"
          onClick={resetFilters}
          disabled={query() === '' && publisherFilter() === ''}
        >
          Reset
        </button>
      </div>

      <div class="filter-group">
        <select
          value={publisherFilter()}
          onChange={(e) => handlePublisherChange(e.currentTarget.value)}
        >
          <option value="">All Publishers</option>
          {props.allPublishers.map((pub) => (
            <option value={pub}>{pub}</option>
          ))}
        </select>
      </div>
    </div>
  );
};
