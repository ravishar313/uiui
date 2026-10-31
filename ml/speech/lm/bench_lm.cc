// Native per-step cost of the LM lookup (KenLM trie, the format a port would read).  Replays real hypothesis token streams: at each
// emitted token, scores K candidate tokens (the emitted one + K-1 sampled from the training token stream) from the current state, then
// advances.  Reports ns per BaseScore call and us per step.  usage: bench_lm model.bin hyps_ids.txt train_ids.txt [K=16]
#include "lm/model.hh"
#include <chrono>
#include <cstdio>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>
using namespace lm::ngram;
int main(int argc, char **argv) {
  if (argc < 4) return 1;
  int K = argc > 4 ? atoi(argv[4]) : 16;
  Config cfg; cfg.load_method = util::POPULATE_OR_READ;
  QuantTrieModel m(argv[1], cfg);
  const auto &v = m.GetVocabulary();
  auto readIds = [&](const char *p, size_t maxLines) {
    std::vector<std::vector<lm::WordIndex>> out; std::ifstream f(p); std::string l;
    while (std::getline(f, l) && out.size() < maxLines) { std::istringstream s(l); std::string w; std::vector<lm::WordIndex> r; while (s >> w) r.push_back(v.Index(w)); out.push_back(r); }
    return out; };
  auto hyps = readIds(argv[2], 100000); auto train = readIds(argv[3], 20000);
  std::vector<lm::WordIndex> pool; for (auto &r : train) for (auto w : r) pool.push_back(w);
  std::mt19937 rng(0);
  size_t steps = 0, calls = 0; double sink = 0;
  auto t0 = std::chrono::steady_clock::now();
  for (int rep = 0; rep < 3; rep++)
    for (auto &h : hyps) {
      State s = m.BeginSentenceState(), o;
      for (auto w : h) {
        for (int k = 0; k < K; k++) { lm::WordIndex c = k == 0 ? w : pool[rng() % pool.size()]; sink += m.FullScore(s, c, o).prob; calls++; }
        m.FullScore(s, w, o); State t = o; s = t; steps++;
      }
    }
  double sec = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  printf("order %d  K=%d  steps %zu  lookups %zu  total %.3fs  => %.0f ns/lookup, %.2f us/step (sink %.1f)\n", (int)m.Order(), K, steps, calls, sec,
         1e9 * sec / (calls + steps), 1e6 * sec / steps, sink);
}
