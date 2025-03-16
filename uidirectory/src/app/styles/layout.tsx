import Link from "next/link";

const styleOptions = [{ name: "Minimalism", slug: "minimalism" }];

export default function StylesLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="flex flex-col min-h-screen bg-neutral-50 text-neutral-900">
      {/* Header */}
      <header className="flex justify-between items-center p-4 border-b border-neutral-200">
        <Link href="/" className="text-xl font-semibold">
          ui.directory
        </Link>
      </header>

      {/* Main Content */}
      <div className="flex flex-1">
        {/* Left Sidebar - Style Navigation */}
        <aside className="w-64 border-r border-neutral-200 p-4">
          <ul className="space-y-2">
            {styleOptions.map((style) => (
              <li key={style.slug}>
                <Link
                  href={`/styles/${style.slug}`}
                  className="block p-2 hover:bg-neutral-100 rounded"
                >
                  {style.name}
                </Link>
              </li>
            ))}
          </ul>
        </aside>

        {/* Center Content - Style Examples */}
        <main className="flex-1 overflow-y-auto">{children}</main>
      </div>
    </div>
  );
}
