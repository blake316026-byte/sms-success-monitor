export const overdueLimit = 20 * 60 * 1000;
const formatter = new Intl.DateTimeFormat('en-GB', {timeZone:'Asia/Shanghai', hourCycle:'h23',
  year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit'});
export const validCreatedAt = value => typeof value === 'number' && Number.isSafeInteger(value)
  && value >= 946684800000 && value < 4102444800000;
export function creationText(value) {
  if (!validCreatedAt(value)) return '未获取';
  const p=Object.fromEntries(formatter.formatToParts(new Date(value)).map(x=>[x.type,x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`;
}
export function pendingTiming(row, now=Date.now()) {
  if (!validCreatedAt(row.createdAt)) return {overdue:false,text:'时间未获取'};
  const elapsed=now-row.createdAt;
  if (elapsed<0) return {overdue:false,text:'时间异常'};
  const minutes=Math.floor(elapsed/60000);
  const duration=minutes<60?minutes+' 分钟':Math.floor(minutes/60)+' 小时 '+minutes%60+' 分';
  const overdue=row.confirmed===true&&elapsed>overdueLimit;
  return {overdue,text:(overdue?'超时 · ':'')+duration+(row.confirmed===true?'':'（待核实）')};
}
