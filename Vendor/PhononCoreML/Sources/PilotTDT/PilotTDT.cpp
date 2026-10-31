// Isolated UIUI pilot: compact quantized TDT scoring from published model
// architecture. No transcript rewriting. Apache-2.0; see LICENSE/NOTICE.
#include "pilot_tdt.h"
#include "phonon2_tdt.h"
#include "QuantizedMatrix.h"
#include "ContextGate.hpp"
#include <cstdlib>
#include <cstdio>
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <new>
#include <queue>
#include <unordered_map>
#include <vector>
#include <cstring>
using Vec = std::vector<float>;
static float half(uint16_t bits) { return pilot::decodeHalf(bits); }
using Matrix = pilot::QuantizedMatrix;
static Vec bias(const uint16_t *b,int n) { Vec v(n); for(int i=0;i<n;i++)v[i]=half(b[i]); return v; }
// Float-format (v3) biases: dtype 0 = float32, 1 = float16.
static Vec biasAny(const void *b,int n,int dtype) { if(dtype==1)return bias((const uint16_t*)b,n); Vec v(n); std::memcpy(v.data(),b,size_t(n)*sizeof(float)); return v; }
struct Tables { bool floatTables=false; int V,E,H,nhead,blank,maxsym; std::vector<int> durations; Matrix emb,ih[2],hh[2],proj,head; Vec ib[2],hb[2],pb,jb; };
struct Node { std::unordered_map<int,int> go; int fail=0,depth=0; bool complete=false; };
struct PilotHandle { std::shared_ptr<Tables> t; void *reference=nullptr; bool useReference=false; bool predictorCacheEnabled=true; int customWorkers=1; uint64_t predictorCacheHits=0,predictorCacheMisses=0; float strength=0; std::vector<Node> trie{Node{}}; std::vector<uint8_t> suppressed,boundaries,wordStarts; bool selective=false; int contextMode=-1; double contextLoss=0,contextWeight=1; float localMargin=2; int attempts=0,commits=0,steps=0; float acceptedRegret=0; const float *fixtureScores=nullptr; pilot_cancel_fn cancel=nullptr; void *cancelContext=nullptr; bool aborted=false; int configurationFailurePoint=0; bool configurationFailed=false; int predictionBudget=0,fixturePredictionBudget=0;std::vector<int32_t> fixtureTokens,fixtureFrames,fixtureDurations; ~PilotHandle(){ if(reference)phonon2_tdt_destroy(reference); } };
// Configuration setters cannot let a C++ allocation exception cross Swift's C
// ABI. Quarantine a failed handle without allocating; callers check the sticky
// status and discard it before publishing a replacement pool.
static void disableConfiguration(PilotHandle &h) noexcept {
    h.configurationFailed=true;h.trie.clear();h.strength=0;h.useReference=true;h.selective=false;
    h.suppressed.clear();h.boundaries.clear();h.wordStarts.clear();
}
static void configurationAllocationPoint(PilotHandle &h,int point) {
    // Set only by the deterministic model-free failure diagnostic below.
    if(h.configurationFailurePoint==point)throw std::bad_alloc();
}
extern "C" {
void *pilot_tdt_create(int V,int E,int H,int nhead,int ndur,const int *durations,int blank,int max_sym,
const int8_t *emb_q,const uint16_t *emb_s,
const int8_t *ih0_q,const uint16_t *ih0_s,const uint16_t *bih0,const int8_t *hh0_q,const uint16_t *hh0_s,const uint16_t *bhh0,
const int8_t *ih1_q,const uint16_t *ih1_s,const uint16_t *bih1,const int8_t *hh1_q,const uint16_t *hh1_s,const uint16_t *bhh1,
const int8_t *proj_q,const uint16_t *proj_s,const uint16_t *proj_b,const int8_t *head_q,const uint16_t *head_s,const uint16_t *head_b) {
    if(V<=0||E<=0||H<=0||blank<0||blank>=V||nhead!=V+ndur||ndur<=0||max_sym<=0) return nullptr;
    try {
    auto h=std::make_unique<PilotHandle>(); auto t=std::make_shared<Tables>(); h->t=t;
    t->V=V;t->E=E;t->H=H;t->nhead=nhead;t->blank=blank;t->maxsym=max_sym;t->durations.assign(durations,durations+ndur);
    t->emb=Matrix(emb_q,emb_s,V,E);t->ih[0]=Matrix(ih0_q,ih0_s,4*H,E);t->hh[0]=Matrix(hh0_q,hh0_s,4*H,H);
    t->ih[1]=Matrix(ih1_q,ih1_s,4*H,H);t->hh[1]=Matrix(hh1_q,hh1_s,4*H,H);
    t->ib[0]=bias(bih0,4*H);t->hb[0]=bias(bhh0,4*H);t->ib[1]=bias(bih1,4*H);t->hb[1]=bias(bhh1,4*H);
    t->proj=Matrix(proj_q,proj_s,H,H);t->head=Matrix(head_q,head_s,nhead,H);t->pb=bias(proj_b,H);t->jb=bias(head_b,nhead);
    h->reference=phonon2_tdt_create(V,E,H,nhead,ndur,durations,blank,max_sym,emb_q,emb_s,ih0_q,ih0_s,bih0,hh0_q,hh0_s,bhh0,ih1_q,ih1_s,bih1,hh1_q,hh1_s,bhh1,proj_q,proj_s,proj_b,head_q,head_s,head_b);
    if(!h->reference)return nullptr;
    return h.release();
    } catch (...) { return nullptr; }
}
// Float-format (decoder.bin v3) tables: uncompressed float32 (dtype 0) or float16 (dtype 1) matrices, fp32 accumulate.
// The compiled reference decoder only understands int8 codes, so these handles use the custom decode path exclusively.
void *pilot_tdt_create_float(int V,int E,int H,int nhead,int ndur,const int *durations,int blank,int max_sym,int dtype,
const void *emb,const void *ih0,const void *bih0,const void *hh0,const void *bhh0,
const void *ih1,const void *bih1,const void *hh1,const void *bhh1,
const void *proj,const void *proj_b,const void *head,const void *head_b) {
    if(V<=0||E<=0||H<=0||blank<0||blank>=V||nhead!=V+ndur||ndur<=0||max_sym<=0||(dtype!=0&&dtype!=1)) return nullptr;
    if(!durations||!emb||!ih0||!bih0||!hh0||!bhh0||!ih1||!bih1||!hh1||!bhh1||!proj||!proj_b||!head||!head_b) return nullptr;
    try {
    auto h=std::make_unique<PilotHandle>(); auto t=std::make_shared<Tables>(); h->t=t;
    t->V=V;t->E=E;t->H=H;t->nhead=nhead;t->blank=blank;t->maxsym=max_sym;t->durations.assign(durations,durations+ndur);
    t->emb=Matrix(emb,dtype,V,E);t->ih[0]=Matrix(ih0,dtype,4*H,E);t->hh[0]=Matrix(hh0,dtype,4*H,H);
    t->ih[1]=Matrix(ih1,dtype,4*H,H);t->hh[1]=Matrix(hh1,dtype,4*H,H);
    t->ib[0]=biasAny(bih0,4*H,dtype);t->hb[0]=biasAny(bhh0,4*H,dtype);t->ib[1]=biasAny(bih1,4*H,dtype);t->hb[1]=biasAny(bhh1,4*H,dtype);
    t->proj=Matrix(proj,dtype,H,H);t->head=Matrix(head,dtype,nhead,H);t->pb=biasAny(proj_b,H,dtype);t->jb=biasAny(head_b,nhead,dtype);
    for(const Vec *v:{&t->ib[0],&t->hb[0],&t->ib[1],&t->hb[1],&t->pb,&t->jb})for(float x:*v)if(!std::isfinite(x))return nullptr;
    t->floatTables=true;h->useReference=false;
    return h.release();
    } catch (...) { return nullptr; }
}
void *pilot_tdt_clone(void *raw) {
    if(!raw)return nullptr;
    try {
        auto src=(PilotHandle*)raw;
        auto h=std::make_unique<PilotHandle>();
        h->t=src->t;if(src->reference){h->reference=phonon2_tdt_clone(src->reference);
        if(!h->reference)return nullptr;}
        h->useReference=src->useReference;h->predictorCacheEnabled=src->predictorCacheEnabled;h->customWorkers=src->customWorkers;h->strength=src->strength;
        h->trie=src->trie;h->suppressed=src->suppressed;
        h->boundaries=src->boundaries;h->wordStarts=src->wordStarts;
        h->selective=src->selective;h->contextMode=src->contextMode;
        h->contextLoss=src->contextLoss;h->contextWeight=src->contextWeight;
        h->localMargin=src->localMargin;
        h->cancel=src->cancel;h->cancelContext=src->cancelContext;
        h->configurationFailed=src->configurationFailed;
        return h.release();
    } catch (...) { return nullptr; }
}
int pilot_tdt_configuration_status(void *raw){return !raw?-1:(((PilotHandle*)raw)->configurationFailed?1:0);}
void pilot_tdt_destroy(void *raw){delete (PilotHandle*)raw;}
void pilot_tdt_reference(void *raw,int enabled){if(raw)((PilotHandle*)raw)->useReference=enabled!=0;}
void pilot_tdt_predictor_cache(void *raw,int enabled){if(raw)((PilotHandle*)raw)->predictorCacheEnabled=enabled!=0;}
void pilot_tdt_predictor_cache_statistics(void *raw,uint64_t *hits,uint64_t *misses){
    if(!raw)return;const auto &h=*(PilotHandle*)raw;
    if(hits)*hits=h.predictorCacheHits;if(misses)*misses=h.predictorCacheMisses;
}
void pilot_tdt_set_threads(int n){phonon2_tdt_set_threads(n);}
void pilot_tdt_handle_threads(void *raw,int n){if(raw){auto &h=*(PilotHandle*)raw;h.customWorkers=std::clamp(n,1,4);if(h.reference)phonon2_tdt_handle_threads(h.reference,n);}}
int pilot_tdt_abi_version(){return 1;}
void pilot_tdt_bias(void *raw,const int32_t *tokens,const int32_t *lengths,int count,float strength){
    if(!raw)return;auto h=(PilotHandle*)raw;
    try {
    configurationAllocationPoint(*h,1);h->trie={Node{}};h->strength=0;
    if(!std::isfinite(strength)||strength<=0||strength>8||count<0||count>2400)return;
    int offset=0;
    for(int i=0;i<count;i++){
        if(lengths[i]<=0||lengths[i]>128){h->trie={Node{}};return;} int s=0;
        for(int j=0;j<lengths[i];j++){
            int tok=tokens[offset++];if(tok<0||tok>=h->t->V||tok==h->t->blank){h->trie={Node{}};return;}
            if(!h->trie[s].go.count(tok)) {if(h->trie.size()>=8192){h->trie={Node{}};return;}int d=h->trie[s].depth+1;int id=(int)h->trie.size();h->trie[s].go[tok]=id;h->trie.push_back(Node{});h->trie.back().depth=d;}
            s=h->trie[s].go[tok];
        }
        h->trie[s].complete=true;
    }
    std::queue<int> q;for(auto kv:h->trie[0].go)q.push(kv.second);
    while(!q.empty()) {int s=q.front();q.pop();for(auto kv:h->trie[s].go){int f=h->trie[s].fail;while(f&&!h->trie[f].go.count(kv.first))f=h->trie[f].fail;auto it=h->trie[f].go.find(kv.first);h->trie[kv.second].fail=(it!=h->trie[f].go.end()&&it->second!=kv.second)?it->second:0;q.push(kv.second);}}
    h->strength=strength;
    } catch (...) { disableConfiguration(*h); }
}
}
static int next(const PilotHandle &h,int s,int tok){if(h.trie.empty())return 0;while(s&&!h.trie[s].go.count(tok))s=h.trie[s].fail;auto it=h.trie[s].go.find(tok);return it==h.trie[s].go.end()?0:it->second;}
static float tokenBonus(const PilotHandle &h,int state,int token) {
    if(h.strength<=0||token==h.t->blank||(!h.suppressed.empty()&&h.suppressed[token]))return 0;
    const int dest=next(h,state,token);
    return h.strength*std::max(0,h.trie[dest].depth-h.trie[state].depth);
}
extern "C" void pilot_tdt_suppress_tokens(void *raw,const int32_t *tokens,int count) {
    if(!raw)return;auto &h=*(PilotHandle*)raw;
    try {
    configurationAllocationPoint(h,2);h.suppressed.assign(h.t->V,0);
    if(count<0||count>h.t->V||(count>0&&!tokens))return;
    for(int i=0;i<count;i++)if(tokens[i]>=0&&tokens[i]<h.t->V)h.suppressed[tokens[i]]=1;
    } catch (...) { disableConfiguration(h); }
}
static float sig(float x){return 1.f/(1.f+std::exp(-x));}
struct StepTiming { int predicted, advance, symbols; };
static StepTiming stepTiming(int predicted,bool blank,int priorSymbols,int maxSymbols) {
    int advance = blank && predicted == 0 ? 1 : predicted;
    int symbols = advance == 0 ? priorSymbols + 1 : 0;
    if(advance == 0 && symbols >= maxSymbols) { advance = 1; symbols = 0; }
    // Native ABI reports the raw duration prediction, even when the safety cap
    // forces advancement. Preserve that timing convention without changing t.
    return {predicted, advance, symbols};
}
// Prediction state belongs to one token path. It is advanced only on a nonblank
// emission, and each speculative branch carries its own duration/frame counters.
// The predictor depends only on immutable nonblank history, never the encoder
// frame. Copies of a speculative state share this lazy cache, including copies
// made before the first predictor computation. Each nonblank installs a new
// history; blank/duration/frame advancement retains the existing history.
struct PredictorCache { Vec hs[2],cs[2],projected; };
struct PredictorHistory {
    const Vec hs[2],cs[2]; const int last;
    mutable std::shared_ptr<const PredictorCache> cache;
    explicit PredictorHistory(const Tables &w):hs{Vec(w.H),Vec(w.H)},cs{Vec(w.H),Vec(w.H)},last(w.blank){}
    PredictorHistory(int token,const Vec (&nextH)[2],const Vec (&nextC)[2]):hs{nextH[0],nextH[1]},cs{nextC[0],nextC[1]},last(token){}
};
struct DecodeState {
    std::shared_ptr<PredictorHistory> history; int t=0,nsym=0;
    DecodeState(const Tables &w):history(std::make_shared<PredictorHistory>(w)){}
};
struct Prediction { Vec hs[2],cs[2],logits; int token=0,duration=0; };
struct Emission {int token,frame,duration;};
static int floatReferenceDecode(PilotHandle &h,const float *encp,int T,int32_t *out,int32_t *frames,int32_t *durs,int cap);
static int referenceDecode(PilotHandle &h,const float *encp,int T,int32_t *out,int32_t *frames,int32_t *durs,int cap){
    if(h.fixtureScores){int n=std::min(cap,(int)h.fixtureTokens.size());for(int i=0;i<n;i++){out[i]=h.fixtureTokens[i];if(frames)frames[i]=h.fixtureFrames[i];if(durs)durs[i]=h.fixtureDurations[i];}return n;}
    if(!h.reference)return h.t&&h.t->floatTables?floatReferenceDecode(h,encp,T,out,frames,durs,cap):0;   // float-format tables have no compiled reference: the unbiased reference is the plain greedy decode over the same float weights
    if(!frames||!durs)return phonon2_tdt_decode(h.reference,encp,T,out,cap);
    return phonon2_tdt_decode_timed(h.reference,encp,T,out,frames,durs,cap);
}
static Prediction predict(PilotHandle &h,const DecodeState &s,const float *encp) {
    auto &w=*h.t;Prediction p;h.steps++;
    if(h.fixtureScores){
        const float *row=h.fixtureScores+(s.t*w.V+s.history->last)*w.nhead;
        p.logits.assign(row,row+w.nhead);for(int j=1;j<w.V;j++)if(p.logits[j]>p.logits[p.token])p.token=j;
        int did=0;for(int j=1;j<(int)w.durations.size();j++)if(p.logits[w.V+j]>p.logits[w.V+did])did=j;p.duration=w.durations[did];
        for(int l=0;l<2;l++){p.hs[l]=s.history->hs[l];p.cs[l]=s.history->cs[l];}return p;
    }
    std::shared_ptr<const PredictorCache> cached;
    if(h.predictorCacheEnabled && s.history->cache){
        cached=s.history->cache;h.predictorCacheHits++;
    } else {
        auto computed=std::make_shared<PredictorCache>();
        Vec x=w.emb.row(s.history->last);
        for(int l=0;l<2;l++){
            Vec g=w.ih[l].apply(x,w.ib[l],h.customWorkers);Vec r=w.hh[l].apply(s.history->hs[l],w.hb[l],h.customWorkers);computed->hs[l].resize(w.H);computed->cs[l].resize(w.H);
            for(int j=0;j<4*w.H;j++)g[j]+=r[j];
            for(int j=0;j<w.H;j++){computed->cs[l][j]=sig(g[w.H+j])*s.history->cs[l][j]+sig(g[j])*std::tanh(g[2*w.H+j]);computed->hs[l][j]=sig(g[3*w.H+j])*std::tanh(computed->cs[l][j]);}x=computed->hs[l];
        }
        computed->projected=w.proj.apply(x,w.pb,h.customWorkers);
        cached=computed;h.predictorCacheMisses++;
        if(h.predictorCacheEnabled)s.history->cache=cached;
    }
    for(int l=0;l<2;l++){p.hs[l]=cached->hs[l];p.cs[l]=cached->cs[l];}
    // Frame-dependent activation, head, duration and logits are always fresh.
    Vec joint=cached->projected;for(int j=0;j<w.H;j++)joint[j]=std::max(0.f,joint[j]+encp[s.t*w.H+j]);p.logits=w.head.apply(joint,w.jb,h.customWorkers);
    for(int j=1;j<w.V;j++)if(p.logits[j]>p.logits[p.token])p.token=j;
    int did=0;for(int j=1;j<(int)w.durations.size();j++)if(p.logits[w.V+j]>p.logits[w.V+did])did=j;
    p.duration=w.durations[did];return p;
}
static void advance(DecodeState &s,const Prediction &p,int tok,const Tables &w,std::vector<Emission> &out) {
    auto timing=stepTiming(p.duration,tok==w.blank,s.nsym,w.maxsym);
    if(tok!=w.blank){out.push_back({tok,s.t,timing.predicted});s.history=std::make_shared<PredictorHistory>(tok,p.hs,p.cs);}
    s.t+=timing.advance;s.nsym=timing.symbols;
}
// Unbiased reference for float-format (v3) tables: plain greedy TDT decode over
// the SAME float weights (no trie bonus, no speculation, no prediction budget).
// It stands in for the compiled int8 reference, which v3 handles do not have.
// Diagnostic counters are restored so the reference pass is invisible to the
// prediction budget and cache statistics; only cancellation is honored.
static int floatReferenceDecode(PilotHandle &h,const float *encp,int T,int32_t *out,int32_t *frames,int32_t *durs,int cap){
    const int steps=h.steps;const uint64_t hits=h.predictorCacheHits,misses=h.predictorCacheMisses;
    DecodeState s(*h.t);std::vector<Emission> emitted;
    while(s.t<T&&(int)emitted.size()<cap){
        if(h.cancel&&h.cancel(h.cancelContext)){h.aborted=true;break;}
        Prediction p=predict(h,s,encp);advance(s,p,p.token,*h.t,emitted);
    }
    h.steps=steps;h.predictorCacheHits=hits;h.predictorCacheMisses=misses;
    if(h.aborted)return 0;
    int n=std::min(cap,(int)emitted.size());
    for(int i=0;i<n;i++){out[i]=emitted[i].token;if(frames)frames[i]=emitted[i].frame;if(durs)durs[i]=emitted[i].duration;}
    return n;
}
extern "C" int pilot_predictor_cache_invariant_probe(void){
    try {
        // Exercise real compact GEMVs and recurrent math on tiny, public,
        // deterministic coefficients, with no external decoder/model loading.
        auto tables=std::make_shared<Tables>();auto &w=*tables;
        w.V=3;w.E=w.H=4;w.nhead=5;w.blank=2;w.maxsym=10;w.durations={0,1};
        auto matrix=[](int rows,int cols,int salt){
            std::vector<int8_t> q(size_t(rows)*cols);std::vector<uint16_t> scales(rows,0x2800);
            for(int i=0;i<rows;i++)for(int j=0;j<cols;j++)q[size_t(i)*cols+j]=int8_t((i*7+j*3+salt)%19-9);
            return Matrix(q.data(),scales.data(),rows,cols);
        };
        w.emb=matrix(w.V,w.E,1);w.proj=matrix(w.H,w.H,2);w.head=matrix(w.nhead,w.H,3);
        for(int l=0;l<2;l++){w.ih[l]=matrix(4*w.H,w.H,4+l);w.hh[l]=matrix(4*w.H,w.H,6+l);w.ib[l]=Vec(4*w.H);w.hb[l]=Vec(4*w.H);}
        w.pb=Vec(w.H);w.jb=Vec(w.nhead);
        PilotHandle cached,uncached;cached.t=uncached.t=tables;uncached.predictorCacheEnabled=false;
        DecodeState on(w),off(w);DecodeState branchBeforeFirst=on;
        const float encoder[]={0,0,0,0, 2,3,4,5, 1,1,1,1};int failures=0;
        auto exact=[](const Prediction&a,const Prediction&b){
            if(a.token!=b.token||a.duration!=b.duration||a.logits!=b.logits)return false;
            for(int l=0;l<2;l++)if(a.hs[l]!=b.hs[l]||a.cs[l]!=b.cs[l])return false;
            return true;
        };
        auto firstOn=predict(cached,on,encoder),firstOff=predict(uncached,off,encoder);
        if(!exact(firstOn,firstOff))failures|=1;
        auto branchPrediction=predict(cached,branchBeforeFirst,encoder);
        if(!exact(firstOn,branchPrediction)||cached.predictorCacheHits!=1||cached.predictorCacheMisses!=1)failures|=2;
        const auto originalHistory=on.history;
        firstOn.duration=firstOff.duration=1;std::vector<Emission> emittedOn,emittedOff;
        advance(on,firstOn,w.blank,w,emittedOn);advance(off,firstOff,w.blank,w,emittedOff);
        auto blankOn=predict(cached,on,encoder),blankOff=predict(uncached,off,encoder);
        if(!exact(blankOn,blankOff)||on.history!=originalHistory||cached.predictorCacheHits!=2)failures|=4;
        if(blankOn.logits==firstOn.logits)failures|=8; // Joint/head must use the new frame.
        DecodeState sibling=on;const auto siblingHistory=sibling.history;const auto expectedSibling=blankOff;
        blankOn.duration=blankOff.duration=0;
        advance(on,blankOn,0,w,emittedOn);advance(off,blankOff,0,w,emittedOff);
        auto nonblankOn=predict(cached,on,encoder),nonblankOff=predict(uncached,off,encoder);
        if(!exact(nonblankOn,nonblankOff)||on.history==originalHistory||cached.predictorCacheMisses!=2)failures|=16;
        auto siblingPrediction=predict(cached,sibling,encoder);
        if(sibling.history!=siblingHistory||sibling.history!=originalHistory||!exact(siblingPrediction,expectedSibling)||cached.predictorCacheHits!=3)failures|=32;
        if(emittedOn.size()!=1||emittedOff.size()!=1||on.t!=off.t||on.nsym!=off.nsym||uncached.predictorCacheHits!=0||uncached.predictorCacheMisses!=3)failures|=64;
        return failures;
    } catch (...) { return 128; }
}
static bool boundary(const PilotHandle &h,int tok){return tok>=0&&tok<(int)h.boundaries.size()&&h.boundaries[tok];}
// The budget is a COMPLETE-TERM acoustic regret allowance, not a permanent
// prefix reward. Each forced nonblank choice, including a competitor to blank,
// loses max(logit)-logit(token). The acoustic blank remains an alternative;
// durations use their unmodified argmax. Incomplete paths cannot be committed.
static bool eligible(float total,float step,float budget,float margin,bool complete,bool endBoundary) {
    return std::isfinite(total)&&std::isfinite(step)&&total>=0&&step>=0&&total<=budget&&step<=margin&&complete&&endBoundary;
}
struct Branch {DecodeState s;int node=0;float regret=0,acousticScore=0;std::vector<Emission> out;Branch(const DecodeState &state):s(state){}};
static float acousticScore(const Prediction &p,int token,const Tables &w){
    auto logp=[&](int begin,int end,int chosen){float m=p.logits[begin];for(int i=begin+1;i<end;i++)m=std::max(m,p.logits[i]);float sum=0;for(int i=begin;i<end;i++)sum+=std::exp(p.logits[i]-m);return p.logits[chosen]-m-std::log(sum);};
    int did=0;for(int i=1;i<(int)w.durations.size();i++)if(w.durations[i]==p.duration)did=i;
    return logp(0,w.V,token)+logp(w.V,w.nhead,w.V+did);
}
static bool stopped(PilotHandle &h){if(h.cancel&&h.cancel(h.cancelContext)){h.aborted=true;return true;}return h.predictionBudget>0&&h.steps>=h.predictionBudget;}
static bool propose(PilotHandle &h,const DecodeState &initial,const Prediction &first,const float *encp,int T,Branch &accepted) {
    auto &w=*h.t;std::vector<Branch> active{Branch(initial)};bool found=false;float best=h.strength+1;
    // Hard bounds are independent of transcript/reference; no idle work.
    constexpr int beam=4,maxSteps=32,maxFrames=24;
    for(int k=0;k<maxSteps&&!active.empty();k++){
        std::vector<Branch> pending;
        for(auto &a:active){
            if(stopped(h))return false;
            if(a.s.t>=T){if(eligible(a.regret,0,h.strength,h.localMargin,h.trie[a.node].complete,true)&&a.regret<best){accepted=a;best=a.regret;found=true;}continue;}
            if(a.s.t-initial.t>maxFrames)continue;
            Prediction p=(k==0?first:predict(h,a.s,encp));
            if(h.trie[a.node].complete&&p.token!=w.blank){
                if(eligible(a.regret,0,h.strength,h.localMargin,true,boundary(h,p.token))&&a.regret<best){accepted=a;best=a.regret;found=true;}
                // A spelling ending inside an acoustic word is rejected. A
                // longer configured spelling may still consume its next piece.
            }
            // Greedy blank is allowed while waiting for the next spelling piece.
            if(p.token==w.blank){Branch b=a;b.acousticScore+=acousticScore(p,w.blank,w);advance(b.s,p,w.blank,w,b.out);pending.push_back(std::move(b));}
            for(auto edge:h.trie[a.node].go){
                int tok=edge.first;float loss=p.logits[p.token]-p.logits[tok];
                if(loss>h.localMargin||a.regret+loss>h.strength)continue;
                Branch b=a;b.node=edge.second;b.regret+=loss;b.acousticScore+=acousticScore(p,tok,w);advance(b.s,p,tok,w,b.out);pending.push_back(std::move(b));
            }
        }
        std::stable_sort(pending.begin(),pending.end(),[](const Branch &a,const Branch &b){return a.regret<b.regret||(a.regret==b.regret&&a.node<b.node);});
        if(pending.size()>beam)pending.erase(pending.begin()+beam,pending.end());active=std::move(pending);
    }
    return found;
}
// PILOT_CONTEXT_MODE=off|observe|gate; default observe until development freeze.
// This isolated diagnostic prints only aggregate probabilities/frames, no words.
static bool contextGate(PilotHandle &h,const DecodeState &normalState,const Branch &candidate,
    const float *encp,int T,float normalSpan,int replacedWords) {
    using namespace phonon_context;
    const char *mode=std::getenv("PILOT_CONTEXT_MODE");
    if(h.contextMode==0||(h.fixtureScores&&h.contextMode<0)||(h.contextMode<0&&mode&&std::strcmp(mode,"off")==0))return true;
    const bool enforce=h.contextMode==2||(h.contextMode<0&&mode&&std::strcmp(mode,"gate")==0);
    DecodeState ordinary=normalState, alternative=candidate.s;
    if(std::min(T,ordinary.t)!=std::min(T,alternative.t))return false;
    ordinary.t=alternative.t=std::min(T,ordinary.t);
    std::vector<Emission> scratch;
    auto context=scoreContinuation(ordinary.t,T,{},[&](){
        if(stopped(h))return h.aborted?Stop::cancelled:Stop::prediction_budget;
        return Stop::complete;
    },[&](int frame){
        PairedStep result;
        if(ordinary.t!=frame||alternative.t!=frame)return result;
        auto q=predict(h,ordinary,encp);
        if(stopped(h))return result;
        auto r=predict(h,alternative,encp);
        // Teacher-force the exact ordinary token AND duration event. Its model
        // probability differs under the alternative's independent name history.
        r.duration=q.duration;
        result.ordinary=acousticScore(q,q.token,*h.t);
        result.candidate=acousticScore(r,q.token,*h.t);
        result.nonblank=q.token!=h.t->blank;
        result.wordStart=result.nonblank&&h.wordStarts[q.token];
        const int before=ordinary.t;
        advance(ordinary,q,q.token,*h.t,scratch);scratch.clear();
        advance(alternative,r,q.token,*h.t,scratch);scratch.clear();
        result.advance=ordinary.t-before;
        result.valid=alternative.t==ordinary.t;
        return result;
    });
    Policy policy;policy.spanBudget=h.strength;policy.maxContextLoss=h.contextLoss;policy.contextWeight=h.contextWeight;
    if(const char *loss=std::getenv("PILOT_CONTEXT_MAX_LOSS");h.contextMode<0&&loss){
        char *end=nullptr;double v=std::strtod(loss,&end);
        if(end!=loss&&!*end&&std::isfinite(v)&&v>=0)policy.maxContextLoss=v;
    }
    if(const char *weight=std::getenv("PILOT_CONTEXT_WEIGHT");h.contextMode<0&&weight){
        char *end=nullptr;double v=std::strtod(weight,&end);
        if(end!=weight&&!*end&&std::isfinite(v)&&v>=1&&v<=16)policy.contextWeight=v;
    }
    auto verdict=decide(candidate.acousticScore,normalSpan,context,policy);
    // At EOS, preserve useful single-word names. Multiword collapse with a
    // losing local model score remains ambiguous until more context arrives.
    if(verdict==Verdict::insufficient_context&&context.stop==Stop::no_context&&replacedWords<=1)
        verdict=candidate.acousticScore+h.strength>=normalSpan?Verdict::accept:Verdict::span_loss;
    if(const char *trace=std::getenv("PILOT_CONTEXT_DIAGNOSTICS");trace&&std::strcmp(trace,"1")==0)
        std::fprintf(stderr,"{\"context\":true,\"frame\":%d,\"ordinary_words\":%d,\"name_span\":%.9g,\"ordinary_span\":%.9g,\"name_context\":%.9g,\"ordinary_context\":%.9g,\"context_tokens\":%d,\"context_words\":%d,\"context_events\":%d,\"context_end\":%d,\"stop\":%d,\"verdict\":%d}\n",normalState.t,replacedWords,candidate.acousticScore,normalSpan,context.candidate,context.ordinary,context.tokens,context.words,context.events,context.endFrame,int(context.stop),int(verdict));
    // Budget/cancellation always invalidate speculative work, including observe.
    if(h.aborted||context.stop==Stop::prediction_budget)return false;
    return !enforce||verdict==Verdict::accept;
}
static bool commonHorizon(PilotHandle &h,const DecodeState &initial,const Branch &candidate,const Prediction &first,const float *encp,int T,
    const std::vector<int32_t> &original,const std::vector<int32_t> &originalFrames,const std::vector<int32_t> &originalDurations,int originalCount,int cursor,int &endCursor){
        auto &w=*h.t;const int horizon=std::min(T,candidate.s.t);
        // Commit only a bounded original word span ending at precisely the
        // same encoder-frame word boundary. A long duration cannot swallow
        // arbitrary following words. The ordinary comparison retains its own
        // LSTM state and includes token AND duration log probabilities.
        endCursor=cursor;
        while(endCursor<originalCount&&originalFrames[endCursor]<horizon)endCursor++;
        if(endCursor==cursor)return false;
        if(endCursor<originalCount){if(originalFrames[endCursor]!=horizon||!h.wordStarts[original[endCursor]])return false;}
        else if(horizon<T)return false;
        int words=0;for(int i=cursor;i<endCursor;i++)if(h.wordStarts[original[i]])words++;
        if(words>2)return false;
        DecodeState normal=initial;std::vector<Emission> ordinary;float score=0;int steps=0;
        while(normal.t<horizon&&steps++<64){if(stopped(h))return false;auto q=steps==1?first:predict(h,normal,encp);score+=acousticScore(q,q.token,w);advance(normal,q,q.token,w,ordinary);}
        if(std::min(T,normal.t)!=horizon||(int)ordinary.size()!=endCursor-cursor)return false;
        for(int i=0;i<(int)ordinary.size();i++){int j=cursor+i;if(ordinary[i].token!=original[j]||ordinary[i].frame!=originalFrames[j]||ordinary[i].duration!=originalDurations[j])return false;}
        return candidate.acousticScore+h.strength>=score&&contextGate(h,normal,candidate,encp,T,score,words);
}

// Model-free path test seam. Scores are [T,V,V+2], indexed by actual
// frame and previous emitted symbol; this exercises real speculative state,
// blank/duration advancement, boundary confirmation and completion rollback.
static int pathProbe(const int32_t *tokens,const int32_t *lengths,int count,
    const float *scores,int T,int V,const int32_t *boundaries,int boundaryCount,float budget,float margin,
    int32_t *out,int32_t *frames,int32_t *durations,int cap,int *endFrame,int positiveDuration,bool competition,bool utterance=false,int cancelAfter=0,int predictionLimit=0,bool context=false){
    if(!scores||!out||T<=0||T>64||V<2||V>64||cap<=0)return -1;
    PilotHandle h;h.t=std::make_shared<Tables>();h.t->V=V;h.t->H=1;h.t->E=1;h.t->nhead=positiveDuration>1?V+3:V+2;h.t->blank=V-1;h.t->maxsym=3;h.t->durations=positiveDuration>1?std::vector<int>{0,1,positiveDuration}:std::vector<int>{0,1};
    h.fixtureScores=scores;h.localMargin=margin;h.contextMode=context?2:0;h.boundaries.assign(V,0);h.wordStarts.assign(V,0);
    for(int i=0;i<boundaryCount;i++)if(boundaries[i]>=0&&boundaries[i]<V)h.boundaries[boundaries[i]]=h.wordStarts[boundaries[i]]=1;
    pilot_tdt_bias(&h,tokens,lengths,count,budget);
    DecodeState initial(*h.t);Branch candidate(initial);auto first=predict(h,initial,nullptr);
    if(utterance){
        DecodeState normal(initial);std::vector<Emission> ordinary;
        while(normal.t<T&&(int)ordinary.size()<128){auto q=predict(h,normal,nullptr);advance(normal,q,q.token,*h.t,ordinary);}
        for(auto e:ordinary){h.fixtureTokens.push_back(e.token);h.fixtureFrames.push_back(e.frame);h.fixtureDurations.push_back(e.duration);}
        struct Cancel {int calls=0,after;};Cancel cancelled{0,cancelAfter};
        if(cancelAfter>0){h.cancel=[](void *raw){auto &c=*(Cancel*)raw;return ++c.calls>=c.after?1:0;};h.cancelContext=&cancelled;}
        h.selective=true;h.fixturePredictionBudget=predictionLimit;float dummy=0;
        int n=pilot_tdt_decode_timed(&h,&dummy,T,out,frames,durations,cap);
        if(endFrame)*endFrame=h.commits;return n;
    }
    bool found=propose(h,initial,first,nullptr,T,candidate);
    if(found&&competition){
        DecodeState normal(initial);std::vector<Emission> ordinary;std::vector<int32_t> toks,fr,du;
        while(normal.t<T&&(int)ordinary.size()<128){auto q=predict(h,normal,nullptr);advance(normal,q,q.token,*h.t,ordinary);}
        for(auto e:ordinary){toks.push_back(e.token);fr.push_back(e.frame);du.push_back(e.duration);}
        int end=0;found=commonHorizon(h,initial,candidate,first,nullptr,T,toks,fr,du,(int)toks.size(),0,end);
    }
    if(endFrame)*endFrame=found?candidate.s.t:initial.t;
    if(!found)return 0;int n=std::min(cap,(int)candidate.out.size());
    for(int i=0;i<n;i++){out[i]=candidate.out[i].token;if(frames)frames[i]=candidate.out[i].frame;if(durations)durations[i]=candidate.out[i].duration;}return n;
}
extern "C" int pilot_selective_path_probe(const int32_t *tokens,const int32_t *lengths,int count,const float *scores,int T,int V,const int32_t *boundaries,int boundaryCount,float budget,float margin,int32_t *out,int32_t *frames,int32_t *durations,int cap,int *endFrame){return pathProbe(tokens,lengths,count,scores,T,V,boundaries,boundaryCount,budget,margin,out,frames,durations,cap,endFrame,1,false);}
extern "C" int pilot_selective_competition_probe(const int32_t *tokens,const int32_t *lengths,int count,const float *scores,int T,int V,const int32_t *boundaries,int boundaryCount,float budget,float margin,int32_t *out,int32_t *frames,int32_t *durations,int cap,int *endFrame,int positiveDuration){return pathProbe(tokens,lengths,count,scores,T,V,boundaries,boundaryCount,budget,margin,out,frames,durations,cap,endFrame,positiveDuration,true);}
extern "C" int pilot_selective_utterance_probe(const int32_t *tokens,const int32_t *lengths,int count,const float *scores,int T,int V,const int32_t *boundaries,int boundaryCount,float budget,float margin,int32_t *out,int32_t *frames,int32_t *durations,int cap,int *commits,int cancelAfter,int predictionLimit){return pathProbe(tokens,lengths,count,scores,T,V,boundaries,boundaryCount,budget,margin,out,frames,durations,cap,commits,1,false,true,cancelAfter,predictionLimit);}
extern "C" int pilot_selective_context_competition_probe(const int32_t *tokens,const int32_t *lengths,int count,const float *scores,int T,int V,const int32_t *boundaries,int boundaryCount,float budget,float margin,int32_t *out,int32_t *frames,int32_t *durations,int cap,int *endFrame,int positiveDuration){return pathProbe(tokens,lengths,count,scores,T,V,boundaries,boundaryCount,budget,margin,out,frames,durations,cap,endFrame,positiveDuration,true,false,0,0,true);}
extern "C" int pilot_selective_context_utterance_probe(const int32_t *tokens,const int32_t *lengths,int count,const float *scores,int T,int V,const int32_t *boundaries,int boundaryCount,float budget,float margin,int32_t *out,int32_t *frames,int32_t *durations,int cap,int *commits,int cancelAfter,int predictionLimit){return pathProbe(tokens,lengths,count,scores,T,V,boundaries,boundaryCount,budget,margin,out,frames,durations,cap,commits,1,false,true,cancelAfter,predictionLimit,true);}
// Explicit app/harness setting avoids process-global environment policy. Mode:
// 0=off, 1=observe, 2=gate. Invalid configuration conservatively disables bias.
extern "C" void pilot_tdt_context_weight(void *raw,double weight){
    if(!raw)return;auto &h=*(PilotHandle*)raw;
    if(!std::isfinite(weight)||weight<1||weight>16){h.strength=0;return;}
    h.contextWeight=weight;
}
extern "C" void pilot_tdt_context(void *raw,int mode,double maxLoss){
    if(!raw)return;auto &h=*(PilotHandle*)raw;
    if(mode<0||mode>2||!std::isfinite(maxLoss)||maxLoss<0){h.strength=0;h.contextMode=0;return;}
    h.contextMode=mode;h.contextLoss=maxLoss;
}
extern "C" void pilot_tdt_selective(void *raw,const int32_t *tokens,int count,float localMargin){
    if(!raw)return;auto &h=*(PilotHandle*)raw;
    try {
    configurationAllocationPoint(h,4);
    h.selective=true;h.boundaries.assign(h.t->V,0);
    h.localMargin=std::isfinite(localMargin)?std::max(0.f,std::min(8.f,localMargin)):0;
    if(count<0||count>h.t->V||(count&&!tokens))return;
    for(int i=0;i<count;i++)if(tokens[i]>=0&&tokens[i]<h.t->V)h.boundaries[tokens[i]]=1;
    } catch (...) { disableConfiguration(h); }
}
extern "C" void pilot_tdt_cancellation(void *raw,pilot_cancel_fn callback,void *context){if(!raw)return;auto &h=*(PilotHandle*)raw;h.cancel=callback;h.cancelContext=context;}
extern "C" void pilot_tdt_word_starts(void *raw,const int32_t *tokens,int count){
    if(!raw)return;auto &h=*(PilotHandle*)raw;
    try {
    configurationAllocationPoint(h,3);h.wordStarts.assign(h.t->V,0);if(count<0||count>h.t->V||(count&&!tokens))return;
    for(int i=0;i<count;i++)if(tokens[i]>=0&&tokens[i]<h.t->V)h.wordStarts[tokens[i]]=1;
    } catch (...) { disableConfiguration(h); }
}
extern "C" void pilot_tdt_statistics(void *raw,int *attempts,int *commits,int *steps,float *regret){
    if(!raw)return;auto &h=*(PilotHandle*)raw;if(attempts)*attempts=h.attempts;if(commits)*commits=h.commits;if(steps)*steps=h.steps;if(regret)*regret=h.acceptedRegret;
}
extern "C" int pilot_tdt_weight_memory(void *raw,uint64_t *compactBytes,uint64_t *floatWeightBytes,uint64_t *biasBytes,uint64_t *scratchBytes){
    if(!raw)return -1;const auto &w=*((PilotHandle*)raw)->t;
    const Matrix *matrices[]={&w.emb,&w.ih[0],&w.hh[0],&w.ih[1],&w.hh[1],&w.proj,&w.head};
    uint64_t compact=0,floats=0;
    for(const auto *matrix:matrices){compact+=matrix->compactBytes();floats+=matrix->persistentFloatBytes();}
    if(compactBytes)*compactBytes=compact;if(floatWeightBytes)*floatWeightBytes=floats;
    if(biasBytes)*biasBytes=(w.ib[0].capacity()+w.hb[0].capacity()+w.ib[1].capacity()+w.hb[1].capacity()+w.pb.capacity()+w.jb.capacity())*sizeof(float);
    if(scratchBytes)*scratchBytes=Matrix::scratchBytes*((PilotHandle*)raw)->customWorkers;return 0;
}
extern "C" int pilot_selective_gate_probe(float total,float step,float budget,float margin,int complete,int endBoundary){return eligible(total,step,budget,margin,complete!=0,endBoundary!=0);}
static int decodeTimedImpl(void *raw,const float *encp,int T,int32_t *out,int32_t *frames,int32_t *durs,int cap){
    if(!raw||!encp||T<=0||!out||cap<=0)return 0;auto &h=*(PilotHandle*)raw;auto &w=*h.t;
    h.attempts=h.commits=h.steps=0;h.predictorCacheHits=h.predictorCacheMisses=0;h.acceptedRegret=0;h.aborted=false;h.predictionBudget=h.fixturePredictionBudget>0?h.fixturePredictionBudget:(h.selective?4*T+64:0);
    if(stopped(h))return 0;
    // Original ABI remains the exact anchor; custom scoring retains compact weights.
    auto reference=[&](){return referenceDecode(h,encp,T,out,frames,durs,cap);};
    if(h.useReference&&(h.reference||w.floatTables))return reference();
    std::vector<int32_t> original(cap),originalFrames(cap),originalDurations(cap);int originalCount=0,originalCursor=0;bool aligned=true;
    if(h.selective)originalCount=referenceDecode(h,encp,T,original.data(),originalFrames.data(),originalDurations.data(),cap);
    auto originalResult=[&](){h.commits=0;h.acceptedRegret=0;for(int i=0;i<originalCount;i++){out[i]=original[i];if(frames)frames[i]=originalFrames[i];if(durs)durs[i]=originalDurations[i];}return originalCount;};
    DecodeState s(w);std::vector<Emission> emitted;int state=0;
    while(s.t<T&&(int)emitted.size()<cap){
        if(stopped(h)){if(h.aborted)return 0;return h.selective?originalResult():reference();}
        Prediction p=predict(h,s,encp);int tok=p.token;
        if(h.selective&&aligned&&h.strength>0&&tok!=w.blank&&(emitted.empty()||h.wordStarts[tok])){
            bool plausible=false;for(auto edge:h.trie[0].go)if(p.logits[p.token]-p.logits[edge.first]<=h.localMargin)plausible=true;
            if(plausible){h.attempts++;Branch candidate(s);int endCursor=originalCursor;
                if(propose(h,s,p,encp,T,candidate)&&candidate.out.size()>0&&candidate.regret>0&&commonHorizon(h,s,candidate,p,encp,T,original,originalFrames,originalDurations,originalCount,originalCursor,endCursor)){
                    h.commits++;h.acceptedRegret+=candidate.regret;originalCursor=endCursor;
                    s=std::move(candidate.s);emitted.insert(emitted.end(),candidate.out.begin(),candidate.out.end());continue;
                }
            }
        }
        if(!h.selective){float best=-INFINITY;for(int j=0;j<w.V;j++){float score=p.logits[j]+tokenBonus(h,state,j);if(score>best){best=score;tok=j;}}}
        if(h.selective&&aligned&&tok!=w.blank){
            if(originalCursor>=originalCount||original[originalCursor]!=tok||originalFrames[originalCursor]!=s.t||originalDurations[originalCursor]!=p.duration)aligned=false;
            else originalCursor++;
            // Any change outside the explicitly completed-name transaction,
            // including a changed or missing suffix word, rolls back the whole
            // utterance to the original ABI, retaining its original timings.
            if(!aligned&&h.commits>0)return originalResult();
        }
        advance(s,p,tok,w,emitted);if(tok!=w.blank)state=next(h,state,tok);
    }
    // No completed acoustic alternative won: retain original tokens AND timing,
    // including real-audio numerical differences in the independent FP32 port.
    if(h.aborted)return 0;
    if(h.selective&&(h.commits==0||!aligned||originalCursor!=originalCount||s.t<T))return originalResult();
    int n=std::min(cap,(int)emitted.size());for(int i=0;i<n;i++){out[i]=emitted[i].token;if(frames)frames[i]=emitted[i].frame;if(durs)durs[i]=emitted[i].duration;}return n;
}
// Quantized numerical checks may throw. No exception may cross the C ABI;
// restore the original decoder output, including timing, on safe failure.
extern "C" int pilot_tdt_decode_timed(void *raw,const float *encp,int T,int32_t *out,int32_t *frames,int32_t *durs,int cap){
    try { return decodeTimedImpl(raw,encp,T,out,frames,durs,cap); }
    catch (...) {
        if(!raw||!encp||T<=0||!out||cap<=0)return 0;
        auto &h=*(PilotHandle*)raw;h.commits=0;h.acceptedRegret=0;
        if(h.aborted)return 0;
        try { return referenceDecode(h,encp,T,out,frames,durs,cap); } catch (...) { return 0; }
    }
}
extern "C" int pilot_tdt_decode(void *raw,const float *encp,int T,int32_t *out,int cap){return pilot_tdt_decode_timed(raw,encp,T,out,nullptr,nullptr,cap);}

// Pure score-level diagnostic for focused unit tests; runs no model operations.
extern "C" int pilot_bias_probe_suppressed(const int32_t *tokens,const int32_t *lengths,int count,
const int32_t *emitted,int emittedCount,const float *scores,int V,int blank,float strength,float *bonuses,const int32_t *suppressed,int suppressedCount) {
    if(V<=0||blank<0||blank>=V||!scores||!bonuses)return -1;
    PilotHandle h;h.t=std::make_shared<Tables>();h.t->V=V;h.t->blank=blank;
    pilot_tdt_bias(&h,tokens,lengths,count,strength);if(count>0 && strength>0 && h.trie.size()<=1)return -2;pilot_tdt_suppress_tokens(&h,suppressed,suppressedCount);int state=0;
    for(int i=0;i<emittedCount;i++)if(emitted[i]>=0&&emitted[i]<V&&emitted[i]!=blank)state=next(h,state,emitted[i]);
    int tok=0;float best=-INFINITY;
    for(int j=0;j<V;j++){bonuses[j]=tokenBonus(h,state,j);float score=scores[j]+bonuses[j];if(score>best){best=score;tok=j;}}
    return tok;
}

extern "C" int pilot_tdt_bias_states(void *raw) { return raw ? int(((PilotHandle*)raw)->trie.size()) : 0; }

// Pure diagnostic used to regression-test native duration reporting semantics.
extern "C" int pilot_tdt_timing_probe(int predicted,int isBlank,int priorSymbols,int maxSymbols,int *advance,int *nextSymbols) {
    const auto timing=stepTiming(predicted,isBlank!=0,priorSymbols,maxSymbols);
    if(advance)*advance=timing.advance;if(nextSymbols)*nextSymbols=timing.symbols;return timing.predicted;
}

extern "C" int pilot_bias_probe(const int32_t *tokens,const int32_t *lengths,int count,
const int32_t *emitted,int emittedCount,const float *scores,int V,int blank,float strength,float *bonuses) {
    return pilot_bias_probe_suppressed(tokens,lengths,count,emitted,emittedCount,scores,V,blank,strength,bonuses,nullptr,0);
}

// Model-free deterministic allocation-failure test of every allocating native
// configuration setter. Success means the C ABI returned with a safe reference
// fallback and the existing zero-state failure signal, rather than unwinding.
extern "C" int pilot_configuration_failure_probe(void) {
    try {
        int failures=0;
        const int32_t tokens[]={0,1},lengths[]={2};
        for(int point=1;point<=4;point++) {
            PilotHandle h;h.t=std::make_shared<Tables>();h.t->V=4;h.t->blank=3;
            pilot_tdt_bias(&h,tokens,lengths,1,8);
            if(h.trie.size()<=1)return 16;
            h.configurationFailurePoint=point;
            switch(point) {
            case 1:pilot_tdt_bias(&h,tokens,lengths,1,8);break;
            case 2:pilot_tdt_suppress_tokens(&h,tokens,2);break;
            case 3:pilot_tdt_word_starts(&h,tokens,2);break;
            case 4:pilot_tdt_selective(&h,tokens,2,8);break;
            }
            if(pilot_tdt_configuration_status(&h)!=1||pilot_tdt_bias_states(&h)!=0||!h.useReference||h.selective||h.strength!=0)
                failures|=1<<(point-1);
        }
        return failures;
    } catch (...) { return 32; }
}
