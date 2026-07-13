# /// script
# requires-python = ">=3.11"
# dependencies = ["rank-bm25"]
# ///
from rank_bm25 import BM25Okapi

corpus = [
    "the cat sat on the mat",
    "the dog chased the cat",
    "the bird flew over the house",
    "my package never arrived",
]
tokenized = [doc.lower().split() for doc in corpus]
bm25 = BM25Okapi(tokenized)

print("k1", bm25.k1, "b", bm25.b, "epsilon", bm25.epsilon)
print("avg_idf", repr(bm25.average_idf))
for term in ["the", "cat", "package"]:
    print(f"idf[{term}] =", repr(bm25.idf.get(term)))
for query in ["the cat", "package arrived", "cat cat", "missing"]:
    scores = bm25.get_scores(query.lower().split())
    print(f"scores({query!r}) =", [repr(round(s, 10)) for s in scores])
