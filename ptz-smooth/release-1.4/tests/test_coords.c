/* test_coords.c - host unit tests for coords.c (smooth bridge pure logic). */
#include <math.h>
#include <stdio.h>
#include "bridge.h"

static int fails=0,total=0;
#define CHECK(c,...) do{total++; if(!(c)){fails++; printf("FAIL: ");printf(__VA_ARGS__);printf("  (%s:%d)\n",__FILE__,__LINE__);} }while(0)
#define NEAR(a,b) (fabs((a)-(b))<1e-6)

static void t_speed(void){
    double v;
    CHECK(parse_speed_range("0.5",-1,1,&v)==0&&NEAR(v,0.5),"0.5");
    CHECK(parse_speed_range("-1",-1,1,&v)==0&&NEAR(v,-1.0),"-1");
    CHECK(parse_speed_range("",-1,1,&v)!=0,"empty");
    CHECK(parse_speed_range("1.5",-1,1,&v)!=0,">max");
    CHECK(parse_speed_range("nan",-1,1,&v)!=0,"nan");
    CHECK(parse_speed_range("inf",-1,1,&v)!=0,"inf");
    CHECK(parse_speed_range("0.5x",-1,1,&v)!=0,"trailing");
}
static void t_timeout(void){
    long v;
    CHECK(parse_timeout_ms("",5000,60000,&v)==0&&v==5000,"empty->def");
    CHECK(parse_timeout_ms("1500",5000,60000,&v)==0&&v==1500,"1500");
    CHECK(parse_timeout_ms("0",5000,60000,&v)==0&&v==5000,"0->def");
    CHECK(parse_timeout_ms("999999",5000,60000,&v)==0&&v==60000,"clamp max");
    CHECK(parse_timeout_ms("-5",5000,60000,&v)!=0,"negative");
    CHECK(parse_timeout_ms("abc",5000,60000,&v)!=0,"junk");
}
static void t_norm(void){
    CHECK(NEAR(pos_to_norm(2048,4096,0),0.0),"pan mid");
    CHECK(NEAR(pos_to_norm(0,4096,0),-1.0),"pan 0");
    CHECK(NEAR(pos_to_norm(0,2230,1),1.0),"tilt up=+1");
    CHECK(NEAR(pos_to_norm(2230,2230,1),-1.0),"tilt down=-1");
    CHECK(norm_to_steps(0.1,4096,0,20)==20,"rel +x clamp");
    CHECK(norm_to_steps(0.1,2230,1,20)==-20,"rel +y inverted");
}
static void t_dir(void){
    CHECK(dir_motor("right")==MOTOR_PAN&&dir_sign("right")==1,"right");
    CHECK(dir_motor("left")==MOTOR_PAN&&dir_sign("left")==-1,"left");
    CHECK(dir_motor("down")==MOTOR_TILT&&dir_sign("down")==1,"down");
    CHECK(dir_motor("up")==MOTOR_TILT&&dir_sign("up")==-1,"up");
    CHECK(dir_motor("z")==-1,"unknown");
}
static void t_budget(void){
    double b=0; int n, i, sum=0;
    /* full speed, 20ms tick: ~12 steps/tick, capped at 12 */
    for(i=0;i<10;i++){ n=budget_steps(1.0,&b,20,12); CHECK(n>=10&&n<=12,"full-speed tick ~12 (%d)",n); sum+=n; }
    CHECK(sum>=100,"full speed accumulates");
    /* half speed averages ~6/tick */
    b=0; sum=0; for(i=0;i<10;i++) sum+=budget_steps(0.5,&b,20,12);
    CHECK(sum>=50&&sum<=70,"half speed ~6/tick avg (%d)",sum);
    /* zero speed -> no steps */
    b=0; CHECK(budget_steps(0.0,&b,20,12)==0,"zero speed");
}
int main(void){ t_speed();t_timeout();t_norm();t_dir();t_budget();
    printf("\n%d/%d checks passed\n",total-fails,total); return fails?1:0; }
