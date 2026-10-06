#!/usr/bin/env python3
"""
recoll_to_chroma.py
-------------------
Reads all documents from an existing Recoll/Xapian index and stores
their embeddings in a ChromaDB collection.

Why ChromaDB over sqlite-vec:
  - Handles embedding internally (no manual vector serialization)
  - Built-in persistent storage, no extension loading dance
  - Cleaner API: add/query in plain Python, no SQL needed
  - Metadata filtering built-in (filter by url, title, etc.)
  - Same simplicity: single directory on disk, no server required

Usage:
    python3 recoll_to_chroma.py \
        --recoll-conf ./folder-recoll \
        --db ./folder-chroma

Requirements:
    pip install chromadb sentence-transformers
    # Ubuntu/Debian recoll bindings:
    sudo apt install python3-recoll
"""

import argparse
import sys
from pathlib import Path

try:
    import chromadb
except ImportError:
    sys.exit("Missing: pip install chromadb")

try:
    from sentence_transformers import SentenceTransformer
except ImportError:
    sys.exit("Missing: pip install sentence-transformers")

try:
    from recoll import recoll
except ImportError:
    sys.exit(
        "Missing recoll Python bindings.\n"
        "  Ubuntu/Debian: sudo apt install python3-recoll\n"
        "  Then re-run this script."
    )

MODEL_NAME = "all-MiniLM-L6-v2"
COLLECTION_NAME = "recoll_docs"
BATCH_SIZE = 64
DEFAULT_MODEL_DIR = Path(__file__).resolve().parent / "models" / MODEL_NAME


class LocalSentenceTransformerEmbeddingFunction:
    """Use a persisted local sentence-transformer model for Chroma indexing."""

    def __init__(self, model: SentenceTransformer, model_dir: str = ""):
        self.model = model
        self._model_dir = model_dir

    def __call__(self, input):
        if isinstance(input, str):
            input = [input]
        embeddings = self.model.encode(list(input), convert_to_numpy=True)
        return embeddings.tolist()

    @staticmethod
    def name() -> str:
        return "local-sentence-transformer"

    def get_config(self) -> dict:
        return {"model_dir": self._model_dir}

    @staticmethod
    def build_from_config(config: dict) -> "LocalSentenceTransformerEmbeddingFunction":
        model_dir = config.get("model_dir", "")
        model = SentenceTransformer(model_dir, local_files_only=True)
        return LocalSentenceTransformerEmbeddingFunction(model, model_dir)


def load_model(model_dir: Path, download_model: bool) -> SentenceTransformer:
    model_dir = model_dir.expanduser().resolve()

    if model_dir.exists():
        return SentenceTransformer(str(model_dir), local_files_only=True)

    if not download_model:
        sys.exit(
            "Model not found locally.\n"
            f"Expected: {model_dir}\n"
            "Run again with --download-model while online to download and persist it."
        )

    model_dir.parent.mkdir(parents=True, exist_ok=True)
    model = SentenceTransformer(MODEL_NAME)
    model.save(str(model_dir))
    return SentenceTransformer(str(model_dir), local_files_only=True)


def iter_recoll_docs(conf_dir: str):
    """Yield (id, url, title, text) for every document in the Recoll index."""
    db = recoll.connect(confdir=conf_dir, writable=False)
    query = db.query()
    # Use a date range instead of "*" wildcard — wildcard triggers term
    # expansion which hits Recoll's maxTermExpand limit on large indexes.
    # A date range is a numeric filter with no expansion.
    nresults = query.execute("date:1970-01-01/2099-12-31", stemming=0)
    # nresults is a capped estimate (observed: hard-capped at 1000 regardless
    # of true match count) -- NOT the real total. fetchone() pages through
    # every actual match when looped until None, so iterate on that instead
    # of `for i in range(nresults)`, which silently truncated large indexes.
    print(f"  Recoll reports ~{nresults} (estimate); paging until exhausted...")

    i = 0
    while True:
        doc = query.fetchone()
        if doc is None:
            break
        i += 1
        url     = doc.get("url")     or ""
        title   = doc.get("title")   or ""
        snippet = doc.get("abstract") or ""
        text    = f"{title}\n{snippet}".strip() or url
        yield str(i), url, title, text


def main():
    parser = argparse.ArgumentParser(description="Index Recoll docs into ChromaDB")
    parser.add_argument("--recoll-conf", default="./folder-recoll",
                        help="Path to Recoll config directory")
    parser.add_argument("--db", default="./folder-chroma",
                        help="Output ChromaDB directory (default: ./folder-chroma)")
    parser.add_argument("--reset", action="store_true",
                        help="Delete and recreate the collection if it exists")
    parser.add_argument(
        "--model-dir",
        default=str(DEFAULT_MODEL_DIR),
        help="Directory containing the persisted sentence-transformer model",
    )
    parser.add_argument(
        "--download-model",
        action="store_true",
        help="Download the model once and save it to --model-dir if missing",
    )
    args = parser.parse_args()

    # --- ChromaDB setup ---
    # PersistentClient stores everything in a local directory, no server needed
    client = chromadb.PersistentClient(path=args.db)

    model = load_model(Path(args.model_dir), args.download_model)
    ef = LocalSentenceTransformerEmbeddingFunction(model, str(Path(args.model_dir).expanduser().resolve()))

    if args.reset:
        print(f"Resetting collection '{COLLECTION_NAME}'...")
        client.delete_collection(COLLECTION_NAME)

    collection = client.get_or_create_collection(
        name=COLLECTION_NAME,
        embedding_function=ef,
        metadata={"hnsw:space": "cosine"},  # cosine distance for similarity
    )

    # --- Read Recoll index ---
    print(f"Reading Recoll index from '{args.recoll_conf}'...")
    docs = list(iter_recoll_docs(args.recoll_conf))
    if not docs:
        sys.exit("No documents found in Recoll index.")

    ids     = [d[0] for d in docs]
    urls    = [d[1] for d in docs]
    titles  = [d[2] for d in docs]
    texts   = [d[3] for d in docs]

    # --- Index in batches ---
    # Chroma has a default max batch size of 5461; we use BATCH_SIZE for safety
    total = len(docs)
    print(f"Indexing {total} documents into ChromaDB (batch_size={BATCH_SIZE})...")

    for start in range(0, total, BATCH_SIZE):
        end = min(start + BATCH_SIZE, total)
        collection.upsert(
            ids=ids[start:end],
            documents=texts[start:end],
            metadatas=[
                {"url": urls[i], "title": titles[i]}
                for i in range(start, end)
            ],
        )
        print(f"  {end}/{total}", end="\r")

    print(f"\nDone. Indexed {total} documents into '{args.db}'")
    print()
    print("Query:")
    print(f"  python3 query_chroma.py --db {args.db} --model-dir {args.model_dir} 'your query here'")


if __name__ == "__main__":
    main()
