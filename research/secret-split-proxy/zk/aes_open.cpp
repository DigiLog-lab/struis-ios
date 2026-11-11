// 「秘密の鍵 K で AES-128 をかけると、公開のブロックに対してこの出力になる」ことを emp-zk(QuickSilver)で証明する。
//
//   aes_open <party 1=prover 2=verifier> <port> <AES-non-expanded.txt> <job> [conv]
//   aes_open <party> <port> <AES-non-expanded.txt> calibrate
//
// job: 1行目にブロック数、以降「入力16バイト(hex) 出力のうち見せるバイトの指定16バイト(hex)」。
// prover は標準入力から鍵(hex)を読む。verifier は「OUT <hex>」を1ブロックずつ出す(見せないバイトは 00)。
// 鍵と出力の中身は、標準エラーにも出さない。
#include <emp-tool/emp-tool.h>
#include <emp-zk/emp-zk.h>
#include <openssl/evp.h>

#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

using namespace emp;
using namespace std;

static const int threads = 1;

static vector<uint8_t> unhex(const string& s) {
    vector<uint8_t> out(s.size() / 2);
    for (size_t i = 0; i < out.size(); ++i) out[i] = (uint8_t)stoi(s.substr(2 * i, 2), nullptr, 16);
    return out;
}

static string tohex(const uint8_t* p, size_t n) {
    static const char* d = "0123456789abcdef";
    string s;
    for (size_t i = 0; i < n; ++i) { s += d[p[i] >> 4]; s += d[p[i] & 15]; }
    return s;
}

static void aes_ref(const uint8_t* key, const uint8_t* in, uint8_t* out) {
    EVP_CIPHER_CTX* c = EVP_CIPHER_CTX_new();
    int n = 0;
    EVP_EncryptInit_ex(c, EVP_aes_128_ecb(), nullptr, key, nullptr);
    EVP_CIPHER_CTX_set_padding(c, 0);
    EVP_EncryptUpdate(c, out, &n, in, 16);
    EVP_CIPHER_CTX_free(c);
}

// 回路の線の番号 → 「バイト i/8 の下位から i%8 ビット目」という番号への対応(4通り)
static int bitpos(int conv, int wire) {
    switch (conv) {
        case 0: return wire;
        case 1: return (wire / 8) * 8 + (7 - wire % 8);
        case 2: return 127 - wire;
        default: { int w = 127 - wire; return (w / 8) * 8 + (7 - w % 8); }
    }
}
static bool getbit(const uint8_t* b, int idx) { return (b[idx / 8] >> (idx % 8)) & 1; }
static void setbit(uint8_t* b, int idx, bool v) { if (v) b[idx / 8] |= (uint8_t)(1 << (idx % 8)); }

struct Conv { int key_first; int in_conv; int out_conv; };

static uint64_t sent(BoolIO<NetIO>** ios) {
    uint64_t total = 0;
    for (int i = 0; i < threads; ++i) { ios[i]->flush(); total += ios[i]->io->counter; }
    return total;
}

int main(int argc, char** argv) {
    if (argc < 5) { fprintf(stderr, "usage\n"); return 2; }
    int party = atoi(argv[1]);
    int port = atoi(argv[2]);
    string circuit = argv[3];
    string job = argv[4];
    Conv cv{1, 0, 0};
    if (argc >= 6) sscanf(argv[5], "%d,%d,%d", &cv.key_first, &cv.in_conv, &cv.out_conv);

    auto t0 = chrono::steady_clock::now();
    BoolIO<NetIO>* ios[threads];
    for (int i = 0; i < threads; ++i)
        ios[i] = new BoolIO<NetIO>(new NetIO(party == ALICE ? nullptr : "127.0.0.1", port + i, true), party == ALICE);
    setup_zk_bool<BoolIO<NetIO>>(ios, threads, party);
    uint64_t sent_setup = sent(ios);
    auto t1 = chrono::steady_clock::now();

    BristolFormat cf(circuit.c_str());
    long and_gates = 0;
    {
        ifstream f(circuit);
        string line;
        while (getline(f, line)) if (line.find("AND") != string::npos) ++and_gates;
    }

    if (job == "calibrate") {
        // FIPS-197 の例で、回路のビットの並びを突き止める(鍵は公開の値を使う)
        const vector<uint8_t> key = unhex("000102030405060708090a0b0c0d0e0f");
        const vector<uint8_t> pt = unhex("00112233445566778899aabbccddeeff");
        uint8_t want[16];
        aes_ref(key.data(), pt.data(), want);
        int found = 0;
        for (int kf = 0; kf < 2; ++kf)
            for (int ic = 0; ic < 4; ++ic) {
                Bit k[128], m[128], o[128];
                for (int w = 0; w < 128; ++w) {
                    k[w] = Bit(getbit(key.data(), bitpos(ic, w)), ALICE);
                    m[w] = Bit(getbit(pt.data(), bitpos(ic, w)), PUBLIC);
                }
                if (kf) cf.compute((block*)o, (block*)k, (block*)m);
                else cf.compute((block*)o, (block*)m, (block*)k);
                bool bits[128];
                for (int w = 0; w < 128; ++w) bits[w] = o[w].reveal<bool>(PUBLIC);
                for (int oc = 0; oc < 4; ++oc) {
                    uint8_t got[16] = {0};
                    for (int w = 0; w < 128; ++w) setbit(got, bitpos(oc, w), bits[w]);
                    if (memcmp(got, want, 16) == 0) { printf("CONV %d,%d,%d\n", kf, ic, oc); ++found; }
                }
            }
        bool cheat = finalize_zk_bool<BoolIO<NetIO>>();
        printf("STATS {\"calibrate_found\":%d,\"cheat\":%s,\"and_gates_per_block\":%ld}\n", found, cheat ? "true" : "false", and_gates);
        return found > 0 && !cheat ? 0 : 3;
    }

    // --- 証明 ---
    ifstream jf(job);
    int n = 0;
    jf >> n;
    vector<vector<uint8_t>> blocks(n), masks(n);
    for (int i = 0; i < n; ++i) {
        string a, b;
        jf >> a >> b;
        blocks[i] = unhex(a);
        masks[i] = unhex(b);
    }
    vector<uint8_t> key(16, 0);
    if (party == ALICE) {
        string hexkey;
        getline(cin, hexkey);
        key = unhex(hexkey);
    }
    Bit k[128];
    for (int w = 0; w < 128; ++w) k[w] = Bit(party == ALICE ? getbit(key.data(), bitpos(cv.in_conv, w)) : false, ALICE);

    vector<vector<uint8_t>> outs(n, vector<uint8_t>(16, 0));
    long revealed_bits = 0;
    for (int i = 0; i < n; ++i) {
        Bit m[128], o[128];
        for (int w = 0; w < 128; ++w) m[w] = Bit(getbit(blocks[i].data(), bitpos(cv.in_conv, w)), PUBLIC);
        if (cv.key_first) cf.compute((block*)o, (block*)k, (block*)m);
        else cf.compute((block*)o, (block*)m, (block*)k);
        for (int w = 0; w < 128; ++w) {
            int idx = bitpos(cv.out_conv, w);
            if (masks[i][idx / 8] == 0xff) {
                setbit(outs[i].data(), idx, o[w].reveal<bool>(PUBLIC));
                ++revealed_bits;
            }
        }
    }
    bool cheat = finalize_zk_bool<BoolIO<NetIO>>();
    uint64_t sent_total = sent(ios);
    auto t2 = chrono::steady_clock::now();
    if (cheat) {
        printf("STATS {\"cheat\":true}\n");
        return 3;
    }
    if (party == BOB)
        for (int i = 0; i < n; ++i) printf("OUT %s\n", tohex(outs[i].data(), 16).c_str());
    printf("STATS {\"cheat\":false,\"blocks\":%d,\"and_gates\":%ld,\"revealed_bits\":%ld,"
           "\"sent_setup\":%llu,\"sent_proof\":%llu,\"t_setup\":%.3f,\"t_proof\":%.3f}\n",
           n, and_gates * n, revealed_bits, (unsigned long long)sent_setup,
           (unsigned long long)(sent_total - sent_setup),
           chrono::duration<double>(t1 - t0).count(), chrono::duration<double>(t2 - t1).count());
    for (int i = 0; i < threads; ++i) { delete ios[i]->io; delete ios[i]; }
    return 0;
}
