import { Link } from 'react-router-dom';
import { PageHeader } from '../components/ui';

export default function NotFound() {
  return (
    <>
      <PageHeader title="Page not found" description="The page you requested does not exist." />
      <Link to="/" className="btn-primary inline-block">
        Back to dashboard
      </Link>
    </>
  );
}
