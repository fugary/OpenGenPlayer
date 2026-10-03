#include "config.h"
#include <vlc_common.h>
#include "clock.h"
#include <assert.h>
#include <stdio.h>

const char vlc_module_name[] = "clock-test";

static vlc_tick_t convert(input_clock_t *cl, vlc_tick_t ts, vlc_tick_t audio_duration)
{
    int rate;
    assert(input_clock_ConvertTS(NULL, cl, &rate, &ts, NULL, INT64_MAX, audio_duration) == 0);
    return ts;
}

static void expect_video(input_clock_t *cl, vlc_tick_t stream, vlc_tick_t system, int expected_rate)
{
    int rate;
    assert(input_clock_ConvertTS(NULL, cl, &rate, &stream, NULL, INT64_MAX, 0) == 0);
    assert(llabs(stream - system) <= 1);
    assert(rate == expected_rate);
}

/* Several audio blocks can be submitted at different rates while video is
 * still decoding before the first transition. None of their mappings may be
 * overwritten by the most recent request. A subtitle can span a boundary. */
static void check_queued_video(void)
{
    input_clock_t *cl = input_clock_New(1000);
    input_clock_SetJitter(cl, 3000000, 10);
    bool late;
    const vlc_tick_t now = mdate();
    input_clock_Update(cl, NULL, &late, true, false, 1000001, now);
    const vlc_tick_t first = 2000001;
    convert(cl, first - 40000, 40000);
    const vlc_tick_t first_date = convert(cl, first, 0);
    input_clock_ChangeRate(cl, 500);
    const vlc_tick_t second = first + 40000;
    convert(cl, first, 40000);
    input_clock_ChangeRate(cl, 2000);
    const vlc_tick_t third = second + 40000;
    convert(cl, second, 40000);
    input_clock_ChangeRate(cl, 250);
    for(int i = 0; i < 100; i++) {
        input_clock_ChangeRate(cl, i % 2 ? 250 : 1000);
        expect_video(cl, first - 40000, first_date - 40000, 1000);
        expect_video(cl, first, first_date, 500);
        expect_video(cl, second, first_date + 20000, 2000);
        expect_video(cl, third, first_date + 100000, i % 2 ? 250 : 1000);
    }
    vlc_tick_t start = first - 40000, end = third + 40000;
    int rate;
    assert(input_clock_ConvertTS(NULL, cl, &rate, &start, &end, INT64_MAX, 0) == 0);
    assert(start == first_date - 40000 && end == first_date + 110000);
    input_clock_ChangePause(cl, true, now);
    input_clock_ChangePause(cl, false, now + 3000000);
    expect_video(cl, first - 40000, first_date + 2960000, 1000);
    expect_video(cl, second, first_date + 3020000, 2000);
    input_clock_ChangeSystemOrigin(cl, false, now);
    input_clock_ChangeSystemOrigin(cl, false, now + 500000);
    expect_video(cl, first - 40000, first_date + 3460000, 1000);
    expect_video(cl, second, first_date + 3520000, 2000);
    input_clock_Delete(cl);
}

int main(void)
{
    const int rates[] = {2000, 1333, 1000, 800, 666, 500, 400, 333, 250};
    const vlc_tick_t delays[] = {300000, 1200000, 3000000};
    int cases = 0;
    for (unsigned d=0; d<3; d++) for (unsigned old=0; old<9; old++) for (unsigned next=0; next<9; next++) {
        input_clock_t *cl = input_clock_New(rates[old]);
        input_clock_SetJitter(cl, delays[d], 10);
        bool late;
        const vlc_tick_t now = mdate();
        input_clock_Update(cl, NULL, &late, true, false, 1000001, now);
        input_clock_Update(cl, NULL, &late, true, false, 5000001, now + 4000000LL * rates[old] / 1000);
        const vlc_tick_t audio_end = 4000001;
        convert(cl, audio_end - 50000, 50000);
        vlc_tick_t expected = convert(cl, audio_end, 0);
        const vlc_tick_t queued_video = convert(cl, audio_end - 40000, 0);
        for (int repeat=0; repeat<20; repeat++) {
            int rate = repeat%2 == 0 ? rates[next] : rates[old];
            input_clock_ChangeRate(cl, rate);
            assert(input_clock_GetRate(cl)==rate);
            expect_video(cl, audio_end - 40000, queued_video, rates[old]);
            assert(llabs(convert(cl, audio_end, 0)-expected)<=1);
            assert(llabs(convert(cl, audio_end+1000000, 0)-expected-1000*rate)<=1);
            cases++;
        }
        input_clock_ChangePause(cl, true, now);
        input_clock_ChangeRate(cl, rates[next]);
        input_clock_ChangePause(cl, false, now+3000000);
        assert(llabs(convert(cl, audio_end, 0)-expected-3000000)<=1);
        expect_video(cl, audio_end - 40000, queued_video + 3000000, rates[old]);
        input_clock_Reset(cl);
        input_clock_Update(cl, NULL, &late, true, false, 1000001, now+6000000);
        assert(input_clock_GetRate(cl)==rates[next]);
        input_clock_t *fresh = input_clock_New(rates[next]);
        input_clock_SetJitter(fresh, delays[d], 10);
        input_clock_Update(fresh, NULL, &late, true, false, 1000001, now+6000000);
        input_clock_ChangeRate(cl, rates[old]);
        input_clock_ChangeRate(fresh, rates[old]);
        assert(convert(cl, 2000001, 0)==convert(fresh, 2000001, 0));
        input_clock_Delete(fresh);
        input_clock_Delete(cl);
    }
    check_queued_video();
    printf("PASS %d audio/video rate transitions; 243 pause/resume and reset cases; queued multi-rate video/subtitle mappings\n", cases);
}
