#!/usr/bin/env python3
"""
query_chroma.py
---------------
Query the ChromaDB collection created by recoll_to_chroma.py.

Usage:
    python3 query_chroma.py "your search query"
    python3 query_chroma.py --db ./folder-chroma --top 10 "your query"
    python3 query_chroma.py --where '{"url": {"$contains": ".pdf"}}' "your query"
    python3 query_chroma.py --download-model "your query"

Requirements:
    pip install chromadb sentence-transformers
"""

import argparse
import json
import sys
from pathlib import Path

try:
    import chromadb
    from chromadb.utils.embedding_functions import SentenceTransformerEmbeddingFunction
except ImportError:
    sys.exit("Missing: pip install chromadb")

try:
    from sentence_transformers import SentenceTransformer
except ImportError:
    sys.exit("Missing: pip install sentence-transformers")

MODEL_NAME    = "all-MiniLM-L6-v2"
COLLECTION_NAME = "recoll_docs"
DEFAULT_MODEL_DIR = Path(__file__).resolve().parent / "models" / MODEL_NAME


def ensure_model(model_dir: Path, download: bool) -> str:
    """Return model path string. Download + persist if needed."""
    model_dir = model_dir.expanduser().resolve()

    if model_dir.exists():
        return str(model_dir)

    if not download:
        sys.exit(
            "Model not found locally.\n"
            f"Expected: {model_dir}\n"
            "Run again with --download-model while online to download and persist it."
        )

    model_dir.parent.mkdir(parents=True, exist_ok=True)
    model = SentenceTransformer(MODEL_NAME)
    model.save(str(model_dir))
    return str(model_dir)


def main():
    parser = argparse.ArgumentParser(description="Query a ChromaDB recoll collection")
    parser.add_argument("query", help="Search query text")
    parser.add_argument("--db",  default="./folder-chroma")
    parser.add_argument("--top", type=int, default=5, help="Number of results")
    parser.add_argument("--where", default=None,
                        help="Optional metadata filter as JSON, e.g. '{\"url\": {\"$contains\": \".pdf\"}}'")
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

    client = chromadb.PersistentClient(path=args.db)
    model_path = ensure_model(Path(args.model_dir), args.download_model)
    ef = SentenceTransformerEmbeddingFunction(model_name=model_path)
    collection = client.get_collection(
        name=COLLECTION_NAME,
        embedding_function=ef,
    )

    where = json.loads(args.where) if args.where else None

    results = collection.query(
        query_texts=[args.query],
        n_results=args.top,
        where=where,
        include=["documents", "metadatas", "distances"],
    )

    ids       = results["ids"][0]
    distances = results["distances"][0]
    metadatas = results["metadatas"][0]
    documents = results["documents"][0]

    if not ids:
        print("No results.")
        return

    print(f"\nTop {args.top} results for: '{args.query}'\n")
    for rank, (doc_id, dist, meta, doc) in enumerate(
        zip(ids, distances, metadatas, documents), 1
    ):
        title = meta.get("title") or "(no title)"
        url   = meta.get("url", "")
        # Chroma cosine distance: 0 = identical, 2 = opposite
        # Convert to similarity score (0-1) for readability
        similarity = 1 - (dist / 2)
        print(f"  {rank}. [{similarity:.2%}] {title}")
        print(f"       {url}")
        print(f"       {doc[:120].strip()}...")
        print()


if __name__ == "__main__":
    main()
