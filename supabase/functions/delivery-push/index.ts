import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push";

const cors={ "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type, x-cron-secret", "Access-Control-Allow-Methods":"POST, OPTIONS" };
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"Method not allowed"},405);
 const url=Deno.env.get("SUPABASE_URL")??"",service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")??"";
 const pub=Deno.env.get("VAPID_PUBLIC_KEY")??"",priv=Deno.env.get("VAPID_PRIVATE_KEY")??"",subject=Deno.env.get("VAPID_SUBJECT")??"https://pizza-king-moran.pages.dev";
 if(!url||!service)return json({error:"Supabase server settings are incomplete."},500);
 const admin=createClient(url,service,{auth:{autoRefreshToken:false,persistSession:false}});
 let body:any={};try{body=await req.json()}catch{return json({error:"Invalid JSON"},400)}
 const action=String(body.action??"");
 if(action==="get_public_key")return pub?json({publicKey:pub}):json({error:"VAPID keys are not configured yet."},503);
 const auth=req.headers.get("authorization")??"",token=auth.replace(/^Bearer\s+/i,"");
 if(action==="check_late_orders"){
  const cronSecret=Deno.env.get("DELIVERY_PUSH_CRON_SECRET")??"";
  if(!cronSecret||req.headers.get("x-cron-secret")!==cronSecret)return json({error:"Unauthorized"},401);
  return await sendLateOrders(admin,pub,priv,subject);
 }
 if(!token)return json({error:"Login required"},401);
 const {data:authData,error:authError}=await admin.auth.getUser(token);
 if(authError||!authData.user)return json({error:"Invalid session"},401);
 const uid=authData.user.id;
 const {data:profile,error:profileError}=await admin.from("profiles").select("role,branch").eq("user_id",uid).maybeSingle();
 if(profileError||!profile)return json({error:"Profile not found"},403);
 let repProfile:any=null;
 if(profile.role==="delivery_rep"){
  const rep=await admin.from("delivery_rep_profiles").select("user_id,full_name,branch,is_active").eq("user_id",uid).maybeSingle();
  if(rep.error||!rep.data||!rep.data.is_active)return json({error:"Active delivery representative account required."},403);
  repProfile=rep.data;
 }
 const allowedRoles=["admin","operations_manager","branch_manager","delivery_rep"];
 if(!allowedRoles.includes(profile.role))return json({error:"This account cannot use delivery notifications."},403);
 if(action==="subscribe"){
  const sub=body.subscription;if(!sub?.endpoint||!sub?.keys?.p256dh||!sub?.keys?.auth)return json({error:"Invalid push subscription"},400);
  const branch=profile.role==="branch_manager"?profile.branch:profile.role==="delivery_rep"?repProfile.branch:null;
  const {error}=await admin.from("delivery_push_subscriptions").upsert({user_id:uid,branch,endpoint:sub.endpoint,subscription:sub,updated_at:new Date().toISOString()},{onConflict:"endpoint"});
  return error?json({error:error.message},500):json({success:true});
 }
 if(action==="new_order"){
  if(!["admin","operations_manager","branch_manager"].includes(profile.role))return json({error:"Not allowed"},403);
  const orderId=String(body.order_id??"");if(!orderId)return json({error:"order_id required"},400);
  const {data:order,error}=await admin.from("delivery_orders").select("id,order_no,branch,customer_name,status").eq("id",orderId).maybeSingle();
  if(error||!order)return json({error:"Order not found"},404);
  if(profile.role==="branch_manager"&&profile.branch!==order.branch)return json({error:"Wrong branch"},403);
  const recipients=await admin.from("profiles").select("user_id,role,branch").or("role.eq.admin,role.eq.operations_manager,and(role.eq.branch_manager,branch.eq."+order.branch+")");
  if(recipients.error)return json({error:recipients.error.message},500);
  const ids=(recipients.data??[]).map(x=>x.user_id);
  const sent=await pushToUsers(admin,ids,{title:"طلب دليفري جديد #"+order.order_no,body:"فرع "+order.branch+" — "+order.customer_name,url:"/?view=delivery-orders",tag:"new-order-"+order.id},pub,priv,subject);
  return json({success:true,...sent});
 }
 if(action==="order_assigned"){
  if(!["admin","operations_manager","branch_manager"].includes(profile.role))return json({error:"Not allowed"},403);
  const orderId=String(body.order_id??"");if(!orderId)return json({error:"order_id required"},400);
  const {data:order,error}=await admin.from("delivery_orders").select("id,order_no,branch,customer_name,delivery_address,total_amount,assigned_rep_user_id,status").eq("id",orderId).maybeSingle();
  if(error||!order)return json({error:"Order not found"},404);
  if(profile.role==="branch_manager"&&profile.branch!==order.branch)return json({error:"Wrong branch"},403);
  if(!order.assigned_rep_user_id||!["assigned","accepted","picked_up"].includes(order.status))return json({error:"Order is not assigned to a representative."},409);
  const {data:rep,error:repError}=await admin.from("delivery_rep_profiles").select("user_id,full_name,branch,is_active").eq("user_id",order.assigned_rep_user_id).maybeSingle();
  if(repError||!rep||!rep.is_active||rep.branch!==order.branch)return json({error:"Assigned representative is not active in this branch."},409);
  const sent=await pushToUsers(admin,[rep.user_id],{title:"طلب جديد مسند إليك #"+order.order_no,body:"فرع "+order.branch+" — "+order.customer_name+" — "+Number(order.total_amount||0).toLocaleString("ar-EG")+" ج.م",url:"/?app=delivery",tag:"assigned-order-"+order.id},pub,priv,subject);
  return json({success:true,recipient:rep.full_name,...sent});
 }
 return json({error:"Unknown action"},400);
});
async function pushToUsers(admin:any,ids:string[],payload:any,pub:string,priv:string,subject:string){
 if(!pub||!priv)return {sent:0,failed:0,reason:"VAPID keys not configured"};
 webpush.setVapidDetails(subject,pub,priv);
 const {data:subs,error}=await admin.from("delivery_push_subscriptions").select("id,user_id,endpoint,subscription").in("user_id",ids);
 if(error)return {sent:0,failed:0,error:error.message};
 let sent=0,failed=0;
 for(const row of subs??[]){try{await webpush.sendNotification(row.subscription,JSON.stringify(payload));sent++;}catch(e){failed++;if((e as any)?.statusCode===404||(e as any)?.statusCode===410)await admin.from("delivery_push_subscriptions").delete().eq("id",row.id);}}
 return {sent,failed};
}
async function sendLateOrders(admin:any,pub:string,priv:string,subject:string){
 const cutoff=new Date(Date.now()-45*60*1000).toISOString();
 const {data:orders,error}=await admin.from("delivery_orders").select("id,order_no,branch,customer_name,created_at").lt("created_at",cutoff).not("status","in","(delivered,cancelled)").limit(250);
 if(error)return json({error:error.message},500);
 let notified=0;
 for(const order of orders??[]){
  const key="late-45-"+order.id;
  const {data:existing}=await admin.from("delivery_push_notification_log").select("id").eq("event_key",key).maybeSingle();
  if(existing)continue;
  const recipients=await admin.from("profiles").select("user_id,role,branch").or("role.eq.admin,and(role.eq.branch_manager,branch.eq."+order.branch+")");
  if(recipients.error)continue;
  const ids=(recipients.data??[]).map(x=>x.user_id);
  const result=await pushToUsers(admin,ids,{title:"تأخير طلب #"+order.order_no,body:"طلب فرع "+order.branch+" تخطى 45 دقيقة ولم يتم تسليمه.",url:"/?view=delivery-orders",tag:key},pub,priv,subject);
  if(result.sent>0){await admin.from("delivery_push_notification_log").insert({event_key:key,order_id:order.id});notified++;}
 }
 return json({success:true,checked:orders?.length??0,notified});
}
