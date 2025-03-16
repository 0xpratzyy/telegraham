import Link from "next/link";

// Only keep Minimalism style
const styleOptions = [{ name: "Minimalism", slug: "minimalism" }];

export default function Home() {
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
        <main className="flex-1 p-6 overflow-y-auto">
          <div className="max-w-4xl mx-auto">
            <h1 className="text-3xl font-bold mb-6">UI Style Explorer</h1>
            <p className="text-lg text-neutral-600 mb-8">
              Explore UI design style, see component examples, and generate AI
              prompts for your next project.
            </p>

            <div className="grid grid-cols-1 gap-6">
              {styleOptions.map((style) => (
                <Link
                  href={`/styles/${style.slug}`}
                  key={style.slug}
                  className="block p-6 border border-neutral-200 rounded-lg hover:shadow-md transition-shadow"
                >
                  <h3 className="text-xl font-semibold mb-2">{style.name}</h3>
                  <p className="text-neutral-600">
                    Explore {style.name} UI components and generate prompts
                  </p>
                </Link>
              ))}
            </div>
          </div>
        </main>
      </div>
    </div>
  );
}
