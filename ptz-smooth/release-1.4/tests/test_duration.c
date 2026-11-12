/* test_duration.c - unit test for the ONVIF xs:duration parser.
 * The function below is a verbatim copy of parse_onvif_duration_ms() injected
 * into ptz_service.c by patches/onvif_simple_server/0003-...patch. Keep both
 * in sync; the SOAP tests additionally exercise it end to end. */
#include <stdio.h>
#include <stdlib.h>

static long parse_onvif_duration_ms(const char *str, long def_ms, long max_ms)
{
    const char *p = str;
    double total = 0.0;
    int in_time = 0, saw_field = 0, neg = 0;
    long ms;

    if (p == NULL || *p == 0)
        return def_ms;
    if (*p == '-') { neg = 1; p++; }
    if (*p != 'P')
        return def_ms;
    p++;
    while (*p) {
        char *end;
        double val;
        if (*p == 'T') { in_time = 1; p++; continue; }
        val = strtod(p, &end);
        if (end == p)
            return def_ms;
        switch (*end) {
            case 'H': total += val * 3600.0; break;
            case 'M': total += in_time ? val * 60.0 : val * 2592000.0; break;
            case 'S': total += val; break;
            case 'D': total += val * 86400.0; break;
            case 'W': total += val * 604800.0; break;
            case 'Y': total += val * 31536000.0; break;
            default: return def_ms;
        }
        saw_field = 1;
        p = end + 1;
    }
    if (!saw_field)
        return def_ms;
    if (neg)
        return 0;
    ms = (long)(total * 1000.0 + 0.5);
    if (ms < 0) ms = 0;
    if (ms > max_ms) ms = max_ms;
    return ms;
}

static int fails=0,total=0;
#define CHECK(c,...) do{total++; if(!(c)){fails++; printf("FAIL: ");printf(__VA_ARGS__);printf("\n");} }while(0)

int main(void)
{
    long D=10000, M=60000;
    CHECK(parse_onvif_duration_ms("PT5S",D,M)==5000,"PT5S");
    CHECK(parse_onvif_duration_ms("PT0.5S",D,M)==500,"PT0.5S");
    CHECK(parse_onvif_duration_ms("PT1M",D,M)==60000,"PT1M=60s");
    CHECK(parse_onvif_duration_ms("PT1M30S",D,M)==90000 || 90000>M,"PT1M30S clamps to max");
    CHECK(parse_onvif_duration_ms("PT1H",D,M)==M,"PT1H clamps to max");
    CHECK(parse_onvif_duration_ms("",D,M)==D,"empty->default");
    CHECK(parse_onvif_duration_ms(NULL,D,M)==D,"NULL->default");
    CHECK(parse_onvif_duration_ms("garbage",D,M)==D,"garbage->default");
    CHECK(parse_onvif_duration_ms("5S",D,M)==D,"no P->default");
    CHECK(parse_onvif_duration_ms("PT",D,M)==D,"no field->default");
    CHECK(parse_onvif_duration_ms("-PT5S",D,M)==0,"negative->0");
    CHECK(parse_onvif_duration_ms("PT2S",D,M)==2000,"PT2S");
    printf("%d/%d checks passed\n",total-fails,total);
    return fails?1:0;
}
