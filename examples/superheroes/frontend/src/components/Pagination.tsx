import { Component } from 'solid-js';

interface PaginationProps {
  cursor: string;
  hasMore: boolean;
  loading: boolean;
  onNext: () => void;
  onPrevious: () => void;
}

export const Pagination: Component<PaginationProps> = (props) => {
  return (
    <div class="pagination">
      <button
        class="btn"
        disabled={props.cursor === '' || props.loading}
        type="button"
        onClick={props.onPrevious}
      >
        Previous
      </button>
      <span class="pagination-info">
        {props.loading ? 'Loading...' : 'Page navigation'}
      </span>
      <button
        class="btn"
        disabled={!props.hasMore || props.loading}
        type="button"
        onClick={props.onNext}
      >
        Next
      </button>
    </div>
  );
};
